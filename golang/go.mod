module main

// Substituted at bootstrap from language_version, the same value that picks
// the golang:<version>-bookworm image - so the module and the toolchain it is
// built with cannot drift apart. Override per project:
//   make new golang my_project LANGUAGE_VERSION=1.26
go {{LANGUAGE_VERSION}}

// gig_utils_go is private: the targets' Dockerfiles pass the ssh agent through
// with --mount=type=ssh and rewrite the https url to git@. aws-lambda-go is
// what makes main_lambda a Lambda; fiber serves main_server; uuid tags each
// request. The Dockerfiles run go mod tidy during the build, so anything the
// source stops importing drops out on its own.
require (
	github.com/GIGTennis/gig_utils_go v0.0.89
	github.com/aws/aws-lambda-go v1.55.0
	github.com/gofiber/fiber/v2 v2.52.15
	github.com/google/uuid v1.6.0
)

require (
	github.com/andybalholm/brotli v1.1.0 // indirect
	github.com/aws/aws-sdk-go-v2 v1.41.0 // indirect
	github.com/aws/aws-sdk-go-v2/aws/protocol/eventstream v1.7.4 // indirect
	github.com/aws/aws-sdk-go-v2/config v1.31.8 // indirect
	github.com/aws/aws-sdk-go-v2/credentials v1.18.12 // indirect
	github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue v1.20.23 // indirect
	github.com/aws/aws-sdk-go-v2/feature/dynamodb/expression v1.8.23 // indirect
	github.com/aws/aws-sdk-go-v2/feature/ec2/imds v1.18.7 // indirect
	github.com/aws/aws-sdk-go-v2/feature/s3/manager v1.19.6 // indirect
	github.com/aws/aws-sdk-go-v2/internal/configsources v1.4.16 // indirect
	github.com/aws/aws-sdk-go-v2/internal/endpoints/v2 v2.7.16 // indirect
	github.com/aws/aws-sdk-go-v2/internal/ini v1.8.3 // indirect
	github.com/aws/aws-sdk-go-v2/internal/v4a v1.4.7 // indirect
	github.com/aws/aws-sdk-go-v2/service/cloudwatch v1.53.0 // indirect
	github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs v1.63.0 // indirect
	github.com/aws/aws-sdk-go-v2/service/cognitoidentityprovider v1.57.17 // indirect
	github.com/aws/aws-sdk-go-v2/service/dynamodb v1.52.6 // indirect
	github.com/aws/aws-sdk-go-v2/service/dynamodbstreams v1.32.4 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/accept-encoding v1.13.3 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/checksum v1.8.7 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/endpoint-discovery v1.11.13 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/presigned-url v1.13.7 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/s3shared v1.19.7 // indirect
	github.com/aws/aws-sdk-go-v2/service/lambda v1.87.0 // indirect
	github.com/aws/aws-sdk-go-v2/service/s3 v1.88.1 // indirect
	github.com/aws/aws-sdk-go-v2/service/secretsmanager v1.39.13 // indirect
	github.com/aws/aws-sdk-go-v2/service/sfn v1.39.9 // indirect
	github.com/aws/aws-sdk-go-v2/service/sso v1.29.3 // indirect
	github.com/aws/aws-sdk-go-v2/service/ssooidc v1.34.4 // indirect
	github.com/aws/aws-sdk-go-v2/service/sts v1.38.4 // indirect
	github.com/aws/smithy-go v1.24.0 // indirect
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/dgryski/go-rendezvous v0.0.0-20200823014737-9f7001d12a5f // indirect
	github.com/klauspost/compress v1.18.0 // indirect
	github.com/mattn/go-colorable v0.1.13 // indirect
	github.com/mattn/go-isatty v0.0.20 // indirect
	github.com/mattn/go-runewidth v0.0.16 // indirect
	github.com/redis/go-redis/v9 v9.17.0 // indirect
	github.com/rivo/uniseg v0.2.0 // indirect
	github.com/rs/zerolog v1.34.0 // indirect
	github.com/valyala/bytebufferpool v1.0.0 // indirect
	github.com/valyala/fasthttp v1.51.0 // indirect
	github.com/valyala/tcplisten v1.0.0 // indirect
	golang.org/x/sys v0.37.0 // indirect
)
