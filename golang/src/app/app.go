// Package app is everything the three entrypoints share, so task, server and
// lambda cannot drift apart in behaviour. It mirrors src/main.py in the Python
// layer; the entrypoints beside it mirror main_task.py, main_server.py and
// main_lambda.py.
package app

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/GIGTennis/gig_utils_go/security"
	"github.com/gofiber/fiber/v2"
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

// The port the deployment publishes. Substituted at bootstrap from the same
// value that fills ContainerPort in the CFN targets, so the ALB target group
// and the listener cannot disagree with what the process binds. PORT
// overrides it for a local run.
const DefaultPort = "{{CONTAINER_PORT}}"

func GetMode() Mode {
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

// ProcessRequest is the one function a target calls: the server handler, the
// task loop and the Lambda handler all funnel into it, so the behaviour is the
// same however this is deployed. It mirrors process_request in src/main.py.
func ProcessRequest(ctx context.Context, eventData string, mode Mode) (string, error) {
	if mode == ModeOnline {
		// The one gig_utils call this template demonstrates: anything that
		// must not sit in the environment file - endpoints, credentials, keys
		// - comes from Secrets Manager, read with the task role. Log that it
		// was read, never what it contained.
		secretName := os.Getenv("SECRET_NAME")
		var settings map[string]any
		if err := security.GetSecretAsStruct(ctx, secretName, os.Getenv("AWS_REGION"), &settings); err != nil {
			return "", fmt.Errorf("read %s from secrets manager: %w", secretName, err)
		}
		log.Printf("read %d settings from %s", len(settings), secretName)
	}

	input := map[string]any{"event_data": eventData}
	log.Printf("input: %v", input)

	output := F1(input)

	log.Printf("output: %s for input: %v", output, input)
	return output, nil
}

// healthPath is what the ALB target group checks. It is the alb module's
// default, and ProbeHealth below asks for the same path, so the two cannot
// drift apart.
const healthPath = "/health"

// probeTimeout bounds the self-probe. It runs inside the container against
// its own loopback, so anything slower than this is a hung process rather
// than a slow network.
const probeTimeout = 3 * time.Second

// ProbeHealth asks this process's own health endpoint whether it is serving,
// and is what `server -healthcheck` runs. The container health check calls the
// binary rather than curl: the image is built from a slim base that carries
// neither curl nor wget, and the binary already knows its port and path -
// nothing has to be kept in step with a string in a CloudFormation template.
func ProbeHealth(port string) error {
	// 127.0.0.1 rather than localhost: no DNS lookup, and no IPv6 attempt
	// first in an image whose loopback may have no AAAA record.
	url := "http://127.0.0.1:" + port + healthPath

	client := &http.Client{Timeout: probeTimeout}
	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("probe %s: %w", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("probe %s: status %d", url, resp.StatusCode)
	}

	return nil
}

// Serve is the server target: ECS puts it behind an ALB, which needs
// something listening on ContainerPort and a health check that answers
// without doing any work.
func Serve(port string, mode Mode) error {
	app := fiber.New(fiber.Config{
		AppName:               "{{PROJECT_NAME}}",
		DisableStartupMessage: true,
	})

	// The ALB target group health check. Keep it free of dependencies: if it
	// calls the database, a slow database takes the whole service out.
	app.Get(healthPath, func(c *fiber.Ctx) error {
		return c.JSON(fiber.Map{"status": "ok"})
	})

	app.Post("/", func(c *fiber.Ctx) error {
		output, err := ProcessRequest(c.Context(), string(c.Body()), mode)
		if err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, err.Error())
		}
		return c.JSON(fiber.Map{"output": output})
	})

	log.Printf("listening on :%s in %s mode", port, mode)
	return app.Listen(":" + port)
}
