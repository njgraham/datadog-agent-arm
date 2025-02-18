#!/bin/bash
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
IFS=$'\n\t'
set -euxo pipefail

# version
export AGENT_VERSION=6.11.1

# build dependencies
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python-dev python-virtualenv git curl mercurial bundler

# The agent loads systemd at runtime https://github.com/coreos/go-systemd/blob/a4887aeaa186e68961d2d6af7d5fbac6bd6fa79b/sdjournal/functions.go#L46
# which means it doesn't need to be included in the omnibus build
# but it requires the headers at build time https://github.com/coreos/go-systemd/blob/a4887aeaa186e68961d2d6af7d5fbac6bd6fa79b/sdjournal/journal.go#L27
apt-get install -y libsystemd-dev

# Fixes error when building autoconf
#    configure: error: no acceptable m4 could be found in $PATH.
#    GNU M4 1.4.6 or later is required; 1.4.14 is recommended
apt-get install -y m4

# Fixes error when building libkrb5
#     make[2]: yacc: Command not found
apt-get install -y byacc

if [ "$(dpkg --print-architecture)" == "arm64" ]; then
  # on arm64 building the native extensions for the libffi gem fails. See https://github.com/ffi/ffi/issues/514
  # Installing the library and headers on the build machine fixes it
  apt-get install -y libffi-dev

  # Install Go
  (
    cd /usr/local
    curl -OL https://dl.google.com/go/go1.11.1.linux-arm64.tar.gz
    echo "25e1a281b937022c70571ac5a538c9402dd74bceb71c2526377a7e5747df5522  go1.11.1.linux-arm64.tar.gz" | sha256sum -c -
    tar -xf go1.11.1.linux-arm64.tar.gz
    rm go1.11.1.linux-arm64.tar.gz
  )

elif [ "$(dpkg --print-architecture)" == "armhf" ]; then

  # Install Go
  (
    cd /usr/local
    curl -OL https://dl.google.com/go/go1.11.1.linux-armv6l.tar.gz
    echo "bc601e428f458da6028671d66581b026092742baf6d3124748bb044c82497d42  go1.11.1.linux-armv6l.tar.gz" | sha256sum -c -
    tar -xf go1.11.1.linux-armv6l.tar.gz
    rm go1.11.1.linux-armv6l.tar.gz
  )

else
  echo "Unsupported arch"
  exit 1
fi

export PATH=$PATH:/usr/local/go/bin

# set up gopath and environment
mkdir -p "/opt/agent/go/src" "/opt/agent/go/pkg" "/opt/agent/go/bin"
export GOPATH=/opt/agent/go
export PATH=$GOPATH/bin:$PATH

mkdir -p $GOPATH/src/github.com/DataDog

# git needs this to apply the patches with `git am` we don't actually care about the committer name here
git config --global user.email "you@example.com"
git config --global user.name "Your Name"

# building the agent results in OOO errors on this 2GB machine. Let's give it some swap, it will be slower but it will at least pass!
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

##########################################
#               MAIN AGENT               #
##########################################

# clone the main agent
git clone https://github.com/DataDog/datadog-agent $GOPATH/src/github.com/DataDog/datadog-agent

(
  cd $GOPATH/src/github.com/DataDog/datadog-agent
  git checkout $AGENT_VERSION
  git am /root/0001-Add-dependencies-to-build-wheels-on-ARM-platforms-to.patch
  git am /root/0001-Blacklist-checks-not-building-on-ARM-platforms.patch
  git am /root/0001-Use-omnibus-software-with-patches.patch
  git am /root/0001-Compile-the-process-agent-from-source-within-omnibus.patch
  git am /root/3449.patch
  git tag "$AGENT_VERSION-ak"

  # create virtualenv to hold pip deps
  virtualenv $GOPATH/venv
  set +u; source $GOPATH/venv/bin/activate; set -u

  # install build dependencies
  pip install -r requirements.txt

  # build the agent
  invoke -e agent.omnibus-build --base-dir=$HOME/.omnibus --release-version=$AGENT_VERSION
)
