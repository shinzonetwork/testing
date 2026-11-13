// connprobe opens libp2p connections to one target, each from a fresh peer identity, and reports
// how many the target accepted. Several probes run in one network namespace share a source IP,
// the way every pod behind a k8s SNAT address does, so their totals measure the target's per-IP
// limits.
//
// Modes:
//
//	hold   keep every accepted connection open: measures the concurrent per-IP cap
//	churn  close each connection once accepted: measures the new-connection rate limit
//
// Prints one line "RESULT {json}" to stdout.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/transport/tcp"
)

type result struct {
	Probe        string         `json:"probe"`
	Mode         string         `json:"mode"`
	Attempted    int            `json:"attempted"`
	Connected    int            `json:"connected"`     // Connect returned no error
	Alive        int            `json:"alive"`         // hold: still connected after settle
	Refused      int            `json:"refused"`       // Connect returned an error
	FirstRefusal int            `json:"first_refusal"` // 1-based attempt, 0 if none
	Errors       map[string]int `json:"errors"`
	ElapsedSec   float64        `json:"elapsed_sec"`
}

func main() {
	target := flag.String("target", "", "target multiaddr including /p2p/<id>")
	maxConns := flag.Int("max", 40, "connections to attempt")
	mode := flag.String("mode", "hold", "hold | churn")
	label := flag.String("label", "probe", "name reported in the result")
	dialTimeout := flag.Duration("dial-timeout", 5*time.Second, "per-connection dial timeout")
	settle := flag.Duration("settle", 3*time.Second, "hold: wait before counting live connections")
	hold := flag.Duration("hold", 20*time.Second, "hold: keep connections open this long after reporting")
	flag.Parse()

	if err := run(*target, *maxConns, *mode, *label, *dialTimeout, *settle, *hold); err != nil {
		fmt.Fprintln(os.Stderr, "connprobe:", err)
		os.Exit(1)
	}
}

func run(target string, maxConns int, mode, label string, dialTimeout, settle, hold time.Duration) error {
	if mode != "hold" && mode != "churn" {
		return fmt.Errorf("unknown mode %q", mode)
	}
	info, err := peer.AddrInfoFromString(target)
	if err != nil {
		return fmt.Errorf("parse target: %w", err)
	}

	res := result{Probe: label, Mode: mode, Errors: map[string]int{}}
	var open []host.Host
	defer func() {
		for _, h := range open {
			_ = h.Close()
		}
	}()

	start := time.Now()
	for i := 1; i <= maxConns; i++ {
		// A fresh host per connection: a new peer identity, as each pod has, and no local
		// resource manager, so only the target's limits are measured.
		h, err := libp2p.New(
			libp2p.NoListenAddrs,
			libp2p.DisableRelay(),
			libp2p.Transport(tcp.NewTCPTransport),
			libp2p.ResourceManager(&network.NullResourceManager{}),
		)
		if err != nil {
			return fmt.Errorf("new host: %w", err)
		}
		res.Attempted++

		ctx, cancel := context.WithTimeout(context.Background(), dialTimeout)
		err = h.Connect(ctx, *info)
		cancel()

		switch {
		case err != nil:
			res.Refused++
			if res.FirstRefusal == 0 {
				res.FirstRefusal = i
			}
			res.Errors[shortErr(err)]++
			_ = h.Close()
		case mode == "churn":
			res.Connected++
			_ = h.Close()
			// Let the target see the close before the next dial, so the concurrent cap never
			// binds and only the rate limiter can refuse.
			time.Sleep(50 * time.Millisecond)
		default:
			res.Connected++
			open = append(open, h)
		}
	}
	res.ElapsedSec = time.Since(start).Seconds()

	if mode == "hold" {
		time.Sleep(settle)
		for _, h := range open {
			if h.Network().Connectedness(info.ID) == network.Connected {
				res.Alive++
			}
		}
	}

	out, err := json.Marshal(res)
	if err != nil {
		return err
	}
	fmt.Println("RESULT " + string(out))

	if mode == "hold" {
		// Keep the slots occupied while sibling probes on the same IP finish counting.
		time.Sleep(hold)
	}
	return nil
}

var connAddrs = regexp.MustCompile(`(read|write) tcp[46]? \S+->\S+: `)

// shortErr reduces a swarm dial error, which lists every address tried, to its final cause so
// that errors group by reason rather than by address.
func shortErr(err error) string {
	msg := strings.TrimSpace(err.Error())
	if i := strings.LastIndex(msg, "\n"); i >= 0 {
		msg = strings.TrimSpace(msg[i+1:])
	}
	if i := strings.LastIndex(msg, "] "); i >= 0 {
		msg = msg[i+2:]
	}
	// "read tcp4 a:port->b:port: read: ..." differs by source port on every dial.
	msg = connAddrs.ReplaceAllString(msg, "")
	if len(msg) > 120 {
		msg = msg[:120]
	}
	return msg
}
