// The task target: process one request and exit. Mirrors src/main_task.py.
package main

import (
	"context"
	"encoding/json"
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

	encoded, err := json.Marshal(output)
	if err != nil {
		log.Fatalf("marshal output: %v", err)
	}
	fmt.Println(string(encoded))
}
