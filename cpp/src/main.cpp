#include <chrono>
#include <iostream>
#include <nats/nats.h>
#include <aws/core/Aws.h>
#include <aws/s3/S3Client.h>
#include <aws/dynamodb/DynamoDBClient.h>

#include "imgui.h"
#include "imgui_impl_glfw.h"
#include "imgui_impl_opengl3.h"
#include <GLFW/glfw3.h>

using namespace Aws;
using namespace Aws::Auth;

// Message handler callback
void on_message(natsConnection *nc, natsSubscription *sub, natsMsg *msg, void *closure) {
    const char* data = natsMsg_GetData(msg);
    std::cout << "Received: " << data << std::endl;

    // // Get AWS client from closure
    // auto aws = static_cast<Aws::S3::S3Client*>(closure);

    // // Process with AWS if needed
    // // aws->PutObject(...);

    natsMsg_Destroy(msg);
}

int main()
{
    glfwInit();
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
    #ifdef __APPLE__
        glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GL_TRUE);
    #endif
    GLFWwindow* window = glfwCreateWindow(800, 600, "ImGui", NULL, NULL);
    glfwMakeContextCurrent(window);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui_ImplGlfw_InitForOpenGL(window, true);
    ImGui_ImplOpenGL3_Init("#version 130");

    while (!glfwWindowShouldClose(window)) {
        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplGlfw_NewFrame();
        ImGui::NewFrame();

        ImGui::ShowDemoWindow();

        ImGui::Render();
        ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
        glfwSwapBuffers(window);
        glfwPollEvents();
    }

    glfwTerminate();

    natsConnection *nc = nullptr;
    natsSubscription *sub = nullptr;
    natsStatus status;

    // Initialize AWS
    Aws::SDKOptions options;
    Aws::InitAPI(options);

    Aws::Client::ClientConfiguration config;
    config.region = "ap-southeast-2";
    auto s3_client = std::make_shared<Aws::S3::S3Client>(config);

    // Connect to NATS
    auto server_url = "nats://k8s-default-external-0b802e4465-7b7828d8e5f3b016.elb.ap-southeast-2.amazonaws.com:4224";
    natsOptions *opts = NULL;
    natsOptions_Create(&opts);
    natsOptions_SetURL(opts, server_url);
    natsOptions_SetUserInfo(opts, "tennis-australia", "AlTZALkwIndisHfUrUERbY");
    status = natsConnection_Connect(&nc, opts);
    if (status != NATS_OK) {
        std::cerr << "Error connecting to NATS: " << status << std::endl;
        return 1;
    }
    natsOptions_Destroy(opts);

    // Subscribe
    auto subject = "external.datafeed.realtime.rla";
    status = natsConnection_Subscribe(&sub, nc, subject, on_message, s3_client.get());
    if (status != NATS_OK) {
        std::cerr << "Error subscribing: " << status << std::endl;
        natsConnection_Destroy(nc);
        return 1;
    }

    // Keep running until interrupted
    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }

    // Cleanup
    natsSubscription_Destroy(sub);
    natsConnection_Destroy(nc);
    Aws::ShutdownAPI(options);

    return 0;
}

