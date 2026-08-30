// The server target: listen behind the ALB. Mirrors src/main_server.py.
package main

import (
	"log"
	"os"

	"main/src/app"
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("server: ")

	port := os.Getenv("PORT")
	if port == "" {
		port = app.DefaultPort
	}

	if err := app.Serve(port, app.GetMode()); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
