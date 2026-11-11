// N payloads over one TLS 1.3 connection to bench_server, read with Go's
// crypto/tls (what cloudflared uses towards its origin). Prints JSON per rep.
package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strconv"
	"syscall"
	"time"
)

func cpu() float64 {
	var r syscall.Rusage
	_ = syscall.Getrusage(syscall.RUSAGE_SELF, &r)
	return float64(r.Utime.Sec) + float64(r.Utime.Usec)/1e6 + float64(r.Stime.Sec) + float64(r.Stime.Usec)/1e6
}

func main() {
	port, n := os.Args[1], os.Args[2]
	reps, _ := strconv.Atoi(os.Args[3])
	for i := 0; i < reps; i++ {
		raw, err := net.Dial("tcp", "127.0.0.1:"+port)
		if err != nil {
			panic(err)
		}
		_ = raw.(*net.TCPConn).SetReadBuffer(4 << 20)
		conn := tls.Client(raw, &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS13})
		if err := conn.Handshake(); err != nil {
			panic(err)
		}
		c0, t0 := cpu(), time.Now()
		if _, err := fmt.Fprintf(conn, "%s\n", n); err != nil {
			panic(err)
		}
		buf := make([]byte, 1<<20)
		got := 0
		for {
			k, err := conn.Read(buf)
			got += k
			if err != nil {
				break
			}
		}
		dt := time.Since(t0).Seconds()
		out, _ := json.Marshal(map[string]any{
			"bytes": got, "seconds": dt, "mb_s": float64(got) / dt / 1e6,
			"client_cpu_s": cpu() - c0, "cipher": tls.CipherSuiteName(conn.ConnectionState().CipherSuite),
		})
		fmt.Println(string(out))
		conn.Close()
	}
}
