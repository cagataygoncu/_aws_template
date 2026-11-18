// The server target: listen behind the ALB. Mirrors src/main_server.py.
package main

import (
	"flag"
	"log"
	"os"

	"main/src/app"
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("server: ")

	// -healthcheck is how the container health check probes this process:
	// the same binary, asking its own /health endpoint and reporting through
	// the exit status. It saves putting curl in the image just to run one
	// request, and keeps the port and path in one place.
	probe := flag.Bool("healthcheck", false, "probe the local health endpoint and exit")
	flag.Parse()

	port := os.Getenv("PORT")
	if port == "" {
		port = app.DefaultPort
	}

	if *probe {
		if err := app.ProbeHealth(port); err != nil {
			log.Fatalf("health check failed: %v", err)
		}
		return
	}

	if err := app.Serve(port, app.GetMode()); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
