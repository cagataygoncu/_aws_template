package unit

import (
	"os"
	"strings"
	"testing"

	"main/src/app"
)

// The config object as shipped: a broken services/*.json fails the build.
// Mirrors tests/unit/test_config.py in the Python layer.

// inProjectRoot runs a test from the project root, where container_config.env
// and services/ are - go test starts in this package's directory.
func inProjectRoot(t *testing.T) {
	t.Helper()
	wd, _ := os.Getwd()
	if err := os.Chdir("../.."); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(wd) })
}

func TestShippedConfigResolves(t *testing.T) {
	inProjectRoot(t)
	t.Setenv("CONFIG_KEY", "") // both read from container_config.env
	t.Setenv("CONFIG_BLOCK", "")
	cfg, err := app.LoadConfig(t.Context(), true)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Settings) == 0 {
		t.Fatal("the block resolved to no settings")
	}
}

func TestBlockWinsOverProfile(t *testing.T) {
	data := map[string]any{
		"profiles": map[string]any{"p": map[string]any{"A": 1.0, "B": 1.0}},
		"blk":      map[string]any{"PROFILE": "p", "B": 2.0},
	}
	got, err := app.ResolveBlock(data, "blk")
	if err != nil {
		t.Fatal(err)
	}
	if got["A"] != 1.0 || got["B"] != 2.0 {
		t.Fatalf("got %v", got)
	}
}

func TestMissingBlockAndProfileFail(t *testing.T) {
	if _, err := app.ResolveBlock(map[string]any{}, "blk"); err == nil || !strings.Contains(err.Error(), "no block") {
		t.Fatalf("want a missing-block error, got %v", err)
	}
	data := map[string]any{"blk": map[string]any{"PROFILE": "nope"}}
	if _, err := app.ResolveBlock(data, "blk"); err == nil || !strings.Contains(err.Error(), "names profile") {
		t.Fatalf("want a missing-profile error, got %v", err)
	}
}

func TestUnknownCredentialFails(t *testing.T) {
	err := app.CheckCredentials(map[string]any{"X_CREDENTIAL": "cred_9"}, map[string]app.Credential{"cred_1": {}})
	if err == nil || !strings.Contains(err.Error(), "X_CREDENTIAL=cred_9") {
		t.Fatalf("want an unknown-credential error, got %v", err)
	}
}
