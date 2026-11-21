package app

// The service's configuration: one secret, one config object, one block.
//
// container_config.env names all three:
//
//	AWS_SECRET_NAME   the Secrets Manager secret - credentials and API keys only:
//	                  {"credentials": {"<id>": {"username": ..., "password": ...}},
//	                   "api_keys": {"<id>": "<key>"}}
//	CONFIG_BUCKET     the config object in S3: every other setting, as JSON
//	CONFIG_KEY
//	CONFIG_BLOCK      the block of the config object this deployment runs
//
// A block may name a PROFILE from the object's "profiles"; the block's own keys
// win over its profile's. A setting ending in _CREDENTIAL holds a credential
// id, looked up in the secret - so the same user name can sit under two ids
// with a different password each.
//
// With MODE=local nothing is read from AWS: the config object is the local
// copy, services/<basename of CONFIG_KEY>, and there are no credentials or API
// keys. A local run needs no environment set up: CONFIG_KEY and CONFIG_BLOCK
// it does not have are read from container_config.env, the file ECS loads when
// deployed. Mirrors src/config.py in the Python layer.

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/GIGTennis/gig_utils_go/security"
	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

const (
	credentialSuffix = "_CREDENTIAL"
	envFile          = "container_config.env"
)

// Credential is one entry of the secret's "credentials".
type Credential struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// Config is what a deployment runs with: the resolved block, and the
// credentials and API keys from the secret.
type Config struct {
	Block       string
	Settings    map[string]any
	Credentials map[string]Credential
	APIKeys     map[string]string
}

type secretContent struct {
	Credentials map[string]Credential `json:"credentials"`
	APIKeys     map[string]string     `json:"api_keys"`
}

// Credential returns the credential a *_CREDENTIAL setting names.
func (c Config) Credential(setting string) (Credential, bool) {
	id, _ := c.Settings[setting].(string)
	cred, ok := c.Credentials[id]
	return cred, ok
}

// ResolveBlock returns the block's settings on top of its PROFILE's.
func ResolveBlock(data map[string]any, blockName string) (map[string]any, error) {
	raw, ok := data[blockName]
	if !ok {
		return nil, fmt.Errorf("the config object has no block %q", blockName)
	}
	block, ok := raw.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("block %q is not a JSON object", blockName)
	}
	settings := map[string]any{}
	if profileName, _ := block["PROFILE"].(string); profileName != "" {
		profiles, _ := data["profiles"].(map[string]any)
		profile, ok := profiles[profileName].(map[string]any)
		if !ok {
			return nil, fmt.Errorf("block %q names profile %q, which the config object does not have", blockName, profileName)
		}
		for k, v := range profile {
			settings[k] = v
		}
	}
	for k, v := range block {
		settings[k] = v
	}
	return settings, nil
}

// CheckCredentials fails when a *_CREDENTIAL setting names a credential the
// secret does not hold.
func CheckCredentials(settings map[string]any, credentials map[string]Credential) error {
	var missing []string
	for key, value := range settings {
		if !strings.HasSuffix(key, credentialSuffix) {
			continue
		}
		id, _ := value.(string)
		if _, ok := credentials[id]; !ok {
			missing = append(missing, fmt.Sprintf("%s=%v", key, value))
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return fmt.Errorf("credential ids not in the secret: %s", strings.Join(missing, ", "))
	}
	return nil
}

// setting is an environment variable; for a local run, else
// container_config.env's.
func setting(name string, local bool) string {
	if value := os.Getenv(name); value != "" || !local {
		return value
	}
	f, err := os.Open(envFile)
	if err != nil {
		return ""
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		if value, ok := strings.CutPrefix(scanner.Text(), name+"="); ok {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func readConfigObject(ctx context.Context, local bool) ([]byte, error) {
	key := setting("CONFIG_KEY", local)
	if local {
		if key == "" {
			return nil, fmt.Errorf("CONFIG_KEY is not set")
		}
		return os.ReadFile(filepath.Join("services", filepath.Base(key)))
	}
	bucket := setting("CONFIG_BUCKET", local)
	if bucket == "" || key == "" {
		return nil, fmt.Errorf("CONFIG_BUCKET and CONFIG_KEY must both be set")
	}
	cfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("load AWS config: %w", err)
	}
	obj, err := s3.NewFromConfig(cfg).GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return nil, fmt.Errorf("get s3://%s/%s: %w", bucket, key, err)
	}
	defer obj.Body.Close()
	return io.ReadAll(obj.Body)
}

// LoadConfig reads the configuration; GetConfig is the cached form.
func LoadConfig(ctx context.Context, local bool) (Config, error) {
	blockName := setting("CONFIG_BLOCK", local)
	if blockName == "" {
		return Config{}, fmt.Errorf("CONFIG_BLOCK is not set")
	}
	raw, err := readConfigObject(ctx, local)
	if err != nil {
		return Config{}, err
	}
	var data map[string]any
	if err := json.Unmarshal(raw, &data); err != nil {
		return Config{}, fmt.Errorf("parse the config object: %w", err)
	}
	settings, err := ResolveBlock(data, blockName)
	if err != nil {
		return Config{}, err
	}
	cfg := Config{Block: blockName, Settings: settings}
	if local {
		return cfg, nil
	}
	if name := os.Getenv("AWS_SECRET_NAME"); name != "" {
		var secret secretContent
		if err := security.GetSecretAsStruct(ctx, name, os.Getenv("AWS_REGION"), &secret); err != nil {
			return Config{}, fmt.Errorf("read %s from secrets manager: %w", name, err)
		}
		cfg.Credentials, cfg.APIKeys = secret.Credentials, secret.APIKeys
	}
	if err := CheckCredentials(settings, cfg.Credentials); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

var (
	configOnce   sync.Once
	cachedConfig Config
	configErr    error
)

// GetConfig reads the configuration once, at the first call; a change takes
// a restart.
func GetConfig(ctx context.Context, local bool) (Config, error) {
	configOnce.Do(func() {
		cachedConfig, configErr = LoadConfig(ctx, local)
	})
	return cachedConfig, configErr
}
