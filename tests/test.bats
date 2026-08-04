#!/usr/bin/env bats

setup() {
  set -eu -o pipefail

  export GITHUB_REPO=cortier/ddev-commands
  export BATS_LIB_PATH="${BATS_LIB_PATH:-}:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-ddev-commands-api"
  export TESTDIR="$(mktemp -d)"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true

  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"

  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site
  assert_success

  printf 'additional_hostnames:\n    - commands-local\n' > .ddev/config.host.local.yaml
}

teardown() {
  set -eu -o pipefail

  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true

  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV}" ] && echo "TESTDIR=${TESTDIR}" >> "${GITHUB_ENV}"
  else
    rm -rf "${TESTDIR}"
  fi
}

health_checks() {
  run ddev name
  assert_success
  assert_output "test-ddev-commands"

  run ddev url
  assert_success
  assert_output "https://commands-local.ddev.site"

  run ddev launch --help
  assert_success
  assert_output --partial "Open the local project URL"

  for command in api app launch name surface url; do
    assert_file_executable ".ddev/commands/host/${command}"
    run bash -n ".ddev/commands/host/${command}"
    assert_success
  done
}

@test "install from directory" {
  run ddev add-on get "${DIR}"
  assert_success

  health_checks
}

# bats test_tags=release
@test "install from release" {
  run ddev add-on get "${GITHUB_REPO}"
  assert_success

  health_checks
}
