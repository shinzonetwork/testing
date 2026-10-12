package testing

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/suite"
	tcexec "github.com/testcontainers/testcontainers-go/exec"
	"github.com/testcontainers/testcontainers-go/modules/compose"
)

const (
	// DefraDB API port inside the host container. Compose publishes it on 9281,
	// but the mapped port is resolved at runtime so the suite also works when
	// the ports are remapped.
	hostDefraPort = "9181/tcp"

	graphQLPath = "/api/v0/graphql"

	// The host starts empty and fills up as the generator replicates over
	// libp2p, so the first blocks take a while to show up.
	blockTimeout = 2 * time.Minute
	blockTick    = 5 * time.Second
)

type ShinzoTestSuite struct {
	suite.Suite

	stack *compose.DockerCompose

	// Full GraphQL endpoint of the host, resolved from the running container.
	hostGraphQL string
}

// TestShinzoTestSuite makes sure that `go test` works as expected
func TestShinzoTestSuite(t *testing.T) {
	suite.Run(t, new(ShinzoTestSuite))
}

// SetupSuite is called once before entire suite. It's spins up containers and wait for them.
func (s *ShinzoTestSuite) SetupSuite() {
	s.setupStack("test", "docker-compose.yaml")
}

func (s *ShinzoTestSuite) setupStack(identifier string, files ...string) {
	ctx := s.T().Context()

	stack, err := compose.NewDockerComposeWith(
		compose.StackIdentifier(identifier),
		compose.WithStackFiles(files...),
	)
	s.Require().NoError(err)

	s.stack = stack

	err = stack.Up(ctx, compose.Wait(true))
	s.Require().NoError(err)

	host, err := stack.ServiceContainer(ctx, "host")
	s.Require().NoError(err)

	endpoint, err := host.PortEndpoint(ctx, hostDefraPort, "http")
	s.Require().NoError(err)

	s.hostGraphQL = endpoint + graphQLPath
}

// TearDownSuite is called after all tests to stop and destroy test containers.
func (s *ShinzoTestSuite) TearDownSuite() {
	err := s.stack.Down(s.T().Context(), compose.RemoveOrphans(true), compose.RemoveVolumes(true))
	s.Require().NoError(err)
}

// graphQLResponse is the envelope DefraDB wraps every result in.
type graphQLResponse struct {
	Data   json.RawMessage `json:"data"`
	Errors []struct {
		Message string `json:"message"`
	} `json:"errors"`
}

// query POSTs a GraphQL query to the host and returns the decoded response.
// Transport and HTTP-level problems come back as an error; GraphQL errors are
// left in the response for the caller to judge, as a query against a host that
// has not replicated anything yet is not necessarily a test failure.
func (s *ShinzoTestSuite) query(ctx context.Context, graphQL string) (graphQLResponse, error) {
	return queryGraphQL(ctx, s.hostGraphQL, graphQL)
}

func queryGraphQL(ctx context.Context, endpoint, graphQL string) (graphQLResponse, error) {
	var result graphQLResponse

	type query struct {
		Query string `json:"query"`
	}

	body, err := json.Marshal(query{Query: graphQL})
	if err != nil {
		return result, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return result, err
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/graphql-response+json, application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return result, err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return result, err
	}

	if resp.StatusCode != http.StatusOK {
		return result, fmt.Errorf("unexpected status %s: %s", resp.Status, raw)
	}

	if err := json.Unmarshal(raw, &result); err != nil {
		return result, fmt.Errorf("decoding response %s: %w", raw, err)
	}

	return result, nil
}

func (s *ShinzoTestSuite) TestBasicQuery() {
	ctx := s.T().Context()
	query := `{ Ethereum__Mainnet__Block(limit: 3, order: {number: DESC}) { number hash timestamp } }`

	type block struct {
		Number    int    `json:"number"`
		Hash      string `json:"hash"`
		Timestamp string `json:"timestamp"`
	}

	var payload struct {
		Blocks []block `json:"Ethereum__Mainnet__Block"`
	}

	// retry because blocks can arrive after some time
	s.Require().Eventually(func() bool {
		ctx, cancel := context.WithTimeout(ctx, 1*time.Second)
		defer cancel()
		resp, err := s.query(ctx, query)
		if err != nil || len(resp.Errors) > 0 {
			return false
		}
		err = json.Unmarshal(resp.Data, &payload)
		if err != nil {
			return false
		}

		return len(payload.Blocks) > 0
	}, blockTimeout, blockTick, "host returned no blocks within %s", blockTimeout)

	s.Require().LessOrEqual(len(payload.Blocks), 3)
}

// SharedAnvilTestSuite keeps one host and two independent generators on the
// same chain. It reuses the basic query test and the base suite's teardown.
type SharedAnvilTestSuite struct {
	ShinzoTestSuite
}

func TestSharedAnvilTestSuite(t *testing.T) {
	suite.Run(t, new(SharedAnvilTestSuite))
}

func (s *SharedAnvilTestSuite) SetupSuite() {
	s.setupStack("test-shared-anvil", "docker-compose.yaml", "docker-compose.two-generators.yaml")
}

type chainBlock struct {
	Number int64  `json:"number"`
	Hash   string `json:"hash"`
}

func latestChainBlock(ctx context.Context, endpoint string) (chainBlock, error) {
	response, err := queryGraphQL(ctx, endpoint,
		`{ Ethereum__Mainnet__Block(limit: 1, order: {number: DESC}) { number hash } }`)
	if err != nil {
		return chainBlock{}, err
	}
	if len(response.Errors) != 0 {
		return chainBlock{}, fmt.Errorf("GraphQL errors: %v", response.Errors)
	}
	var payload struct {
		Blocks []chainBlock `json:"Ethereum__Mainnet__Block"`
	}
	if err := json.Unmarshal(response.Data, &payload); err != nil {
		return chainBlock{}, err
	}
	if len(payload.Blocks) == 0 {
		return chainBlock{}, fmt.Errorf("no blocks replicated yet")
	}
	return payload.Blocks[0], nil
}

func (s *SharedAnvilTestSuite) TestReplicationFromEachGenerator() {
	ctx := s.T().Context()
	for _, stopped := range []string{"generator", "generator-2"} {
		s.Run("without-"+stopped, func() {
			container, err := s.stack.ServiceContainer(ctx, stopped)
			s.Require().NoError(err)
			stopTimeout := 30 * time.Second
			s.Require().NoError(container.Stop(ctx, &stopTimeout))
			// Restore the generator even when an assertion fails, so the next
			// subtest starts with both generators available.
			defer func() {
				restartCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
				defer cancel()
				s.Require().NoError(container.Start(restartCtx))
			}()

			// Capture the chain tip after shutdown. Blocks above this height
			// cannot come from the stopped generator, even via buffered updates.
			anvil, err := s.stack.ServiceContainer(ctx, "anvil")
			s.Require().NoError(err)
			code, output, err := anvil.Exec(ctx, []string{"cast", "block-number", "--rpc-url", "http://localhost:8545"}, tcexec.Multiplexed())
			s.Require().NoError(err)
			s.Require().Zero(code)
			raw, err := io.ReadAll(output)
			s.Require().NoError(err)
			baseline, err := strconv.ParseInt(strings.TrimSpace(string(raw)), 10, 64)
			s.Require().NoError(err)
			s.Require().Eventually(func() bool {
				queryCtx, cancel := context.WithTimeout(ctx, time.Second)
				defer cancel()
				block, queryErr := latestChainBlock(queryCtx, s.hostGraphQL)
				return queryErr == nil && block.Number > baseline && block.Hash != ""
			}, blockTimeout, blockTick, "host did not receive new blocks with %s stopped", stopped)
		})
	}
}
