// The task target: process one request and exit. Mirrors src/main_task.py.
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"strings"

	"main/src/app"
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("task: ")

	eventData := "test"
	if len(os.Args) > 1 {
		eventData = strings.Join(os.Args[1:], " ")
	}

	output, err := app.ProcessRequest(context.Background(), eventData, app.GetMode())
	if err != nil {
		log.Fatalf("ProcessRequest: %v", err)
	}

	fmt.Println(output)
}
