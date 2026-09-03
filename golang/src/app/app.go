// Package app is everything the three entrypoints share, so task, server and
// lambda cannot drift apart in behaviour. It mirrors src/main.py in the Python
// layer; the entrypoints beside it mirror main_task.py, main_server.py and
// main_lambda.py.
package app

import (
	"context"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/GIGTennis/gig_utils_go/database"
	"github.com/GIGTennis/gig_utils_go/security"
	"github.com/gofiber/fiber/v2"
	"github.com/google/uuid"
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

// Config is whatever the request handler needs that comes from outside it.
// Online it comes from the environment the deployment sets - container_config.env
// for ECS, the function configuration for Lambda - and this is where a call to
// Secrets Manager or Parameter Store belongs. Locally it is filled in with
// values that need no AWS account.
type Config struct {
	ServiceName string `json:"service_name"`
	Environment string `json:"environment"`
}

func LoadConfig(mode Mode) Config {
	if mode == ModeLocal {
		return Config{ServiceName: "local", Environment: "dev"}
	}
	return Config{
		ServiceName: os.Getenv("SERVICE_NAME"),
		Environment: os.Getenv("ENVIRONMENT"),
	}
}

// GetCache mirrors the Python stub: online reads the Redis endpoints from
// Secrets Manager with the task role and connects; local uses an in-memory
// map, so a local run needs no AWS account and no Redis.
func GetCache(ctx context.Context, mode Mode) (database.Cache, error) {
	if mode == ModeLocal {
		return database.GetCacheInMemory(5 * time.Minute), nil
	}

	var redisConfig database.RedisConfig
	err := security.GetSecretAsStruct(
		ctx,
		os.Getenv("SECRET_NAME"),
		os.Getenv("AWS_REGION"),
		&redisConfig,
	)
	if err != nil {
		return nil, fmt.Errorf("read redis config from secrets manager: %w", err)
	}

	return database.GetCacheRedis(&redisConfig, false)
}

// ProcessRequest is the one function a target calls: the server handler, the
// task loop and the Lambda handler all funnel into it, so the behaviour is the
// same however this is deployed.
func ProcessRequest(ctx context.Context, eventData string, mode Mode) (map[string]any, error) {
	config := LoadConfig(mode)

	cache, err := GetCache(ctx, mode)
	if err != nil {
		return nil, err
	}
	defer cache.Close()

	// A request id makes one request traceable across log lines, which is the
	// only way to follow anything once several run concurrently.
	requestID := uuid.NewString()

	input := map[string]any{"event_data": eventData, "mode": string(mode)}
	log.Printf("[%s] input: %v", requestID, input)

	// Replace this with the work the service actually does. It is here to
	// prove the cache round-trips before anything real depends on it.
	if err := cache.SetValue(ctx, config.ServiceName, requestID, eventData); err != nil {
		return nil, fmt.Errorf("cache write: %w", err)
	}
	var stored string
	if err := cache.GetValue(ctx, config.ServiceName, requestID, &stored); err != nil {
		return nil, fmt.Errorf("cache read: %w", err)
	}

	output := map[string]any{
		"request_id": requestID,
		"service":    config.ServiceName,
		"env":        config.Environment,
		"echo":       stored,
		"length":     len(stored),
	}

	log.Printf("[%s] output: %v for input: %v", requestID, output, input)
	return output, nil
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
	app.Get("/health", func(c *fiber.Ctx) error {
		return c.JSON(fiber.Map{"status": "ok"})
	})

	app.Post("/", func(c *fiber.Ctx) error {
		output, err := ProcessRequest(c.Context(), string(c.Body()), mode)
		if err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, err.Error())
		}
		return c.JSON(output)
	})

	log.Printf("listening on :%s in %s mode", port, mode)
	return app.Listen(":" + port)
}
