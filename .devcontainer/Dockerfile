# The image a Maestro remote session runs this repository in. Minimal on purpose: the base image the
# reference programme (toptal/ai-avatar-research) runs on, plus uv. Maestro layers its own runtime on
# top of whatever is here (claude, gcloud, gh, the slack CLI, sshd, tmux), so this file only needs the
# tools the CODE needs.
#
# Anything installed by hand inside a pod (`apt-get install …` in a terminal) is lost at the next
# image build — a fresh session, a colleague's session, a `resume --latest` — so system packages the
# project needs go here, as one apt-get layer. The kit's `templates/Dockerfile.example` is a full,
# commented example (ffmpeg, espeak-ng, model prefetching) to copy from.
FROM mcr.microsoft.com/devcontainers/python:3.11-trixie
RUN pip install --no-cache-dir uv
