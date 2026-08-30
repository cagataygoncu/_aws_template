package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strings"
)

// Mode decides where the service gets the things it depends on. Deployed code
// is online; a local run opts out with MODE=local.
//
// Online is the default so that nothing has to be set on AWS, and forgetting
// to set it locally fails loudly on the first AWS call rather than silently
// running against stub data in production.
type Mode string

const (
	ModeOnline Mode = "online"
	ModeLocal  Mode = "local"
)

func getMode() Mode {
	mode := Mode(strings.ToLower(os.Getenv("MODE")))
	switch mode {
	case ModeOnline, ModeLocal:
		return mode
	case "":
		return ModeOnline
	default:
		log.Printf("unknown MODE %q, falling back to %s", mode, ModeOnline)
		return ModeOnline
	}
}

// Config is whatever the request handler needs that comes from outside it.
// Online it comes from the environment the deployment sets - container_config.env
// for ECS, the function configuration for Lambda - and this is where a call to
// Secrets Manager or Parameter Store belongs. Locally it is filled in with
// values that need no AWS account.
type Config struct {
	ServiceName string `json:"service_name"`
	Environment string `json:"environment"`
}

func loadConfig(mode Mode) Config {
	if mode == ModeLocal {
		return Config{ServiceName: "local", Environment: "dev"}
	}

	// Add the AWS lookups this service needs here, e.g.
	//   cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
	//   out, err := secretsmanager.NewFromConfig(cfg).GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{
	//       SecretId: aws.String(os.Getenv("SECRET_NAME")),
	//   })
	// The task role already has the permissions; nothing needs credentials.
	return Config{
		ServiceName: os.Getenv("SERVICE_NAME"),
		Environment: os.Getenv("ENVIRONMENT"),
	}
}

// processRequest is the one function a target calls: the server handler, the
// task loop and the Lambda handler all funnel into it, so the behaviour is the
// same however this is deployed.
func processRequest(eventData string, mode Mode) (map[string]any, error) {
	config := loadConfig(mode)

	input := map[string]any{"event_data": eventData, "mode": string(mode)}
	log.Printf("input: %v", input)

	output := map[string]any{
		"service": config.ServiceName,
		"env":     config.Environment,
		"echo":    eventData,
		"length":  len(eventData),
	}

	log.Printf("output: %v for input: %v", output, input)
	return output, nil
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("main: ")

	mode := getMode()

	eventData := "test"
	if len(os.Args) > 1 {
		eventData = strings.Join(os.Args[1:], " ")
	}

	output, err := processRequest(eventData, mode)
	if err != nil {
		log.Fatalf("processRequest: %v", err)
	}

	encoded, err := json.Marshal(output)
	if err != nil {
		log.Fatalf("marshal output: %v", err)
	}
	fmt.Println(string(encoded))
}
