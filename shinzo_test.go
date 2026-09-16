package testing

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/stretchr/testify/suite"
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
	ctx := s.T().Context()

	stack, err := compose.NewDockerComposeWith(
		compose.StackIdentifier("test"),
		compose.WithStackFiles("docker-compose.yaml"),
	)
	s.Require().NoError(err)

	err = stack.Up(ctx, compose.Wait(true))
	s.Require().NoError(err)

	s.stack = stack

	host, err := stack.ServiceContainer(ctx, "host")
	s.Require().NoError(err)

	endpoint, err := host.PortEndpoint(ctx, hostDefraPort, "http")
	s.Require().NoError(err)

	s.hostGraphQL = endpoint + graphQLPath
}

// TeardownSuite is called after all tests to stop and destroy test containers.
func (s *ShinzoTestSuite) TeardownSuite() {
	err := s.stack.Down(s.T().Context())
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
	var result graphQLResponse

	type query struct {
		Query string `json:"query"`
	}

	body, err := json.Marshal(query{Query: graphQL})
	if err != nil {
		return result, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.hostGraphQL, bytes.NewReader(body))
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
