package main

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"net/http"
	"time"

	"runtime"
	"sync"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/nats-io/nats.go"
)

const N_FILE_SAVE_WORKER = 50
const N_SUBSCRIBER = 10

const (
	maxConnections = 50
	bucketName    = "2025-aus-summer-aa"
	natsServer    = "nats://k8s-default-external-0b802e4465-7b7828d8e5f3b016.elb.ap-southeast-2.amazonaws.com:4224"
	natsSubject   = "external.datafeed.realtime.rla"
)

type FileSaveWorkerPool struct {
	workers             chan struct{}
	save_directory_name string
	is_active           int
	client              *s3.Client
}

func create_s3_client() (*s3.Client, error) {
	cfg, err := config.LoadDefaultConfig(context.TODO(),
		config.WithRegion("ap-southeast-2"),
	)
	if err != nil {
		return nil, err
	}

	client := s3.NewFromConfig(cfg, func(o *s3.Options) {
		o.UsePathStyle = true
		o.HTTPClient = &http.Client{
			Transport: &http.Transport{
				MaxIdleConns:        100,
				MaxIdleConnsPerHost: 100,
				MaxConnsPerHost:     100,
				IdleConnTimeout:     90 * time.Second,
			},
		}
	})

	return client, nil
 }

func save_message_with_pool(msg []byte, pool *FileSaveWorkerPool) {
	pool.workers <- struct{}{}
	defer func() { <-pool.workers }()

	save_directory_name := pool.save_directory_name
	timestamp := fmt.Sprintf("%d", time.Now().UnixMicro())
	filename := fmt.Sprintf("%s/%s.json", save_directory_name, timestamp)


    _, err := pool.client.PutObject(context.TODO(), &s3.PutObjectInput{
        Bucket: aws.String(bucketName),
        Key:    aws.String(filename),
        Body:   bytes.NewReader(msg),
    })
	if err != nil {
		log.Printf("Error saving message: %v", err)
	}
}

func handle_message(worker_id int, msg *nats.Msg, pool *FileSaveWorkerPool) {
	if pool.is_active > 0 {
		go save_message_with_pool(msg.Data, pool)
	}
}

func start_queue_subscriber(nc *nats.Conn, worker_id int, subject string, queue_group string, wg *sync.WaitGroup, pool *FileSaveWorkerPool) {
	defer wg.Done()

	sub, err := nc.QueueSubscribe(
		subject,
		queue_group,
		func(msg *nats.Msg) { handle_message(worker_id, msg, pool) },
	)

	if err != nil {
		log.Printf("Worker %d subscription error: %v", worker_id, err)
		return
	}
	defer sub.Unsubscribe()

	// wait forever
	select {}
}

func run_action_audio(pool *FileSaveWorkerPool, court string) {
	numCPU := runtime.NumCPU()
	currentProcs := runtime.GOMAXPROCS(0)

	fmt.Printf("Logical CPUs: %d\n", numCPU)
	fmt.Printf("Current GOMAXPROCS: %d\n", currentProcs)

	n_procs := 2
	fmt.Printf("Setting GOMAXPROCS: %d\n", n_procs)
	runtime.GOMAXPROCS(n_procs)

	var wg sync.WaitGroup
	n_subscriber := N_SUBSCRIBER
	subject := fmt.Sprintf("external.datafeed.realtime.%s", court)
	queue_group := fmt.Sprintf("cggig.realtime.%s", court)

	remote_url := natsServer
	username := "tennis-australia"
	password := "AlTZALkwIndisHfUrUERbY"

	// connect to remote nats server
	remote_nc, err := nats.Connect(remote_url,
		nats.UserInfo(username, password))
	if err != nil {
		log.Fatal(err)
	}
	defer remote_nc.Close()

	for i := 0; i < n_subscriber; i++ {
		wg.Add(1)
		go start_queue_subscriber(remote_nc, i+1, subject, queue_group, &wg, pool)
	}
	wg.Wait()
}

func main() {
	court := "rla"

	n_file_save_worker := N_FILE_SAVE_WORKER
	timestamp := fmt.Sprintf("%d", time.Now().UnixMicro())
	save_directory_name := fmt.Sprintf("messages_golang/%s/%s", court, timestamp)

	client, err := create_s3_client()
	if err != nil {
		log.Printf("Error create_s3_client: %v", err)
	}

	pool := &FileSaveWorkerPool{
		workers:             make(chan struct{}, n_file_save_worker),
		save_directory_name: save_directory_name,
		is_active:           1,
		client:              client,
	}

	run_action_audio(pool, court)
}