FROM --platform=linux/amd64 public.ecr.aws/docker/library/python:{{LANGUAGE_VERSION}}

RUN mkdir -p -m 0600 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts
RUN sed /^StrictHostKeyChecking/d /etc/ssh/ssh_config; \
    echo StrictHostKeyChecking no >> /etc/ssh/ssh_config

COPY .devcontainer/.bashrc /root/.bashrc
COPY .devcontainer/.inputrc /root/.inputrc

COPY ./.devcontainer/requirements_dev.txt /.devcontainer/requirements_dev.txt

# The same list the target images install - one source of truth for the
# runtime dependencies. Dev-only tools stay in .devcontainer/requirements_dev.txt.
COPY requirements.txt requirements.txt

RUN --mount=type=ssh export GIT_SSH_COMMAND="ssh -v" && pip3 install --no-cache-dir --upgrade -r requirements.txt

WORKDIR /

ENV PYTHONPATH=/
