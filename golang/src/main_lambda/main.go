// The lambda target: the runtime invokes Handler. Mirrors src/main_lambda.py.
// Built as `bootstrap`, the entrypoint provided.al2023 expects.
package main

import (
	"context"
	"log"

	"github.com/aws/aws-lambda-go/lambda"

	"main/src/app"
)

// Handler is the function the Lambda runtime calls. The event is passed
// straight to the same ProcessRequest the other two targets use.
func Handler(ctx context.Context, event map[string]any) (map[string]any, error) {
	eventData, _ := event["event_data"].(string)
	output, err := app.ProcessRequest(ctx, eventData, app.GetMode())
	if err != nil {
		return nil, err
	}
	return map[string]any{"output": output}, nil
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("lambda: ")
	lambda.Start(Handler)
}
