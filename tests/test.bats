#!/usr/bin/env bats

setup() {
  set -eu -o pipefail

  export GITHUB_REPO=cortier/ddev-commands
  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH:-}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-ddev-commands-api"
  export TESTDIR="$(mktemp -d)"
  export SURFACE_TEST_ROOT="$(mktemp -d)"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  export GIT_CONFIG_GLOBAL="${TESTDIR}/gitconfig"

  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"

  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site
  assert_success

  printf 'additional_hostnames:\n    - commands-local\n' > .ddev/config.host.local.yaml
}

teardown() {
  set -eu -o pipefail

  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  for surface in api app angular admin shop; do
    ddev delete -Oy "test-surface-${surface}" >/dev/null 2>&1 || true
  done

  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV}" ] && echo "TESTDIR=${TESTDIR}" >> "${GITHUB_ENV}"
  else
    rm -rf "${TESTDIR}"
    rm -rf "${SURFACE_TEST_ROOT}"
  fi
}

configure_surface_project() {
  local surface="$1"
  local type="generic"
  local project_directory="${SURFACE_TEST_ROOT}/${surface}"

  [ "${surface}" != "api" ] || type="laravel"
  mkdir -p "${project_directory}"
  cd "${project_directory}"
  ddev config --project-name="test-surface-${surface}" --project-type="${type}" --project-tld=ddev.site
  printf 'additional_hostnames:\n    - test-surface-%s-local\n' "${surface}" > .ddev/config.host.local.yaml
  ddev add-on get "${DIR}"

  if [ "${surface}" = "api" ]; then
    printf 'API_URL=https://original-api.example\nAPP_URL=https://original-app.example\nAPP_FRONTEND_URL=https://obsolete-app.example\nSHOP_URL=https://original-shop.example\n' > .env
    printf 'REVERB_APP_KEY=test-key\n' > .ddev/.env
  elif [ "${surface}" = "app" ]; then
    printf 'EXISTING_VALUE=preserved\n' > .env.local
  elif [ "${surface}" = "angular" ]; then
    mkdir -p src/environments
    cat > src/environments/environment.ts <<'EOF'
export const environment = {
    apiUrl: 'https://original-api.example',
    pusher: {
        key: 'original-key',
    },
};
EOF
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
  assert_file_not_contains ".ddev/commands/host/launch" "#ddev-generated"
  assert_file_contains ".ddev/commands/host/launch" "# ddev-commands-managed"

  for command in admin angular api app launch name path shop surface url; do
    assert_file_executable ".ddev/commands/host/${command}"
    run bash -n ".ddev/commands/host/${command}"
    assert_success
  done

  assert_file_exist ".ddev/config.ddev-commands.yaml"
  run grep -F "ddev surface auto-connect || true" ".ddev/config.ddev-commands.yaml"
  assert_success
}

@test "resolves configured repository paths" {
  local repository_directory="${TESTDIR}/rules"
  mkdir -p "${repository_directory}"
  git -C "${repository_directory}" init
  git -C "${repository_directory}" remote add origin git@github.com:cortier/rules.git
  git config --global cortier.paths.rules "${repository_directory}"
  ddev add-on get "${DIR}"

  run ddev path rules
  assert_success
  assert_output "${repository_directory}"

  run ddev path rules --json-output
  assert_success
  assert_output "$(jq -n --arg repo rules --arg path "${repository_directory}" '{repo: $repo, path: $path}')"
}

@test "reports how to configure a missing repository path" {
  ddev add-on get "${DIR}"

  run ddev path rules
  assert_failure
  assert_output --partial "git config --global cortier.paths.rules /absolute/path/to/rules"
}

@test "rejects a configured path below the repository root" {
  local repository_directory="${TESTDIR}/rules"
  mkdir -p "${repository_directory}/nested"
  git -C "${repository_directory}" init
  git config --global cortier.paths.rules "${repository_directory}/nested"
  ddev add-on get "${DIR}"

  run ddev path rules
  assert_failure
  assert_output --partial "must be the Git working tree root"
}

@test "install from directory" {
  run ddev add-on get "${DIR}"
  assert_success

  health_checks
}

@test "project launch command survives refresh and add-on updates" {
  run ddev add-on get "${DIR}"
  assert_success

  run ddev start
  assert_success
  assert_file_executable ".ddev/commands/host/launch"

  run ddev launch --help
  assert_success
  assert_output --partial "Open the local project URL"

  printf '# stale version\n' >> .ddev/commands/host/launch
  run ddev add-on get "${DIR}"
  assert_success
  assert_file_not_contains ".ddev/commands/host/launch" "# stale version"
}

@test "add-on removal deletes its project-owned launch command" {
  run ddev add-on get "${DIR}"
  assert_success

  run ddev add-on remove ddev-commands
  assert_success
  assert_file_not_exist ".ddev/commands/host/launch"
}

@test "connects one API to each frontend and validates reciprocal roles" {
  for surface in api app angular admin shop; do
    configure_surface_project "${surface}"
  done

  cd "${SURFACE_TEST_ROOT}/api"
  for surface in app admin shop; do
    run ddev "${surface}" connect test-surface
    assert_success
    assert_file_contains ".ddev/connections/${surface}" "test-surface-${surface}"
    assert_file_contains "${SURFACE_TEST_ROOT}/${surface}/.ddev/connections/api" "test-surface-api"
    assert_file_contains "${SURFACE_TEST_ROOT}/${surface}/.env.local" "VITE_API_URL=https://test-surface-api-local.ddev.site"
  done

  assert_file_contains "${SURFACE_TEST_ROOT}/app/.env.local" "EXISTING_VALUE=preserved"
  assert_file_contains ".env" "API_URL=https://test-surface-api-local.ddev.site"
  assert_file_contains ".env" "APP_URL=https://test-surface-app-local.ddev.site"
  assert_file_contains ".env" "SHOP_URL=https://test-surface-shop-local.ddev.site"
  assert_file_not_contains ".env" "APP_FRONTEND_URL="
  assert_file_contains "${SURFACE_TEST_ROOT}/app/.env.local" "VITE_REVERB_HOST=test-surface-api-local.ddev.site"
  assert_file_contains "${SURFACE_TEST_ROOT}/app/.env.local" "VITE_REVERB_PORT=8880"
  assert_file_contains "${SURFACE_TEST_ROOT}/app/.env.local" "VITE_REVERB_SCHEME=https"
  assert_file_contains "${SURFACE_TEST_ROOT}/app/.env.local" "VITE_REVERB_APP_KEY=test-key"

  run ddev angular connect test-surface
  assert_success
  assert_file_not_exist ".ddev/connections/app"
  assert_file_not_exist "${SURFACE_TEST_ROOT}/app/.ddev/connections/api"
  assert_file_contains ".ddev/connections/angular" "test-surface-angular"
  assert_file_contains "${SURFACE_TEST_ROOT}/angular/.ddev/connections/api" "test-surface-api"
  assert_file_contains ".env" "APP_URL=https://test-surface-angular-local.ddev.site"
  assert_file_contains "${SURFACE_TEST_ROOT}/angular/src/environments/environment.ts" "apiUrl: 'https://test-surface-api-local.ddev.site'"
  assert_file_contains "${SURFACE_TEST_ROOT}/angular/src/environments/environment.ts" "wsHost: 'test-surface-api-local.ddev.site'"
  assert_file_contains "${SURFACE_TEST_ROOT}/angular/src/environments/environment.ts" "wsPort: 8880"
  assert_file_contains "${SURFACE_TEST_ROOT}/angular/src/environments/environment.ts" "key: 'test-key'"

  cd "${SURFACE_TEST_ROOT}/angular"
  run ddev shop connect test-surface
  assert_failure
  assert_output --partial "Connections from angular to shop are not allowed."

  rm .ddev/connections/api
  cd "${SURFACE_TEST_ROOT}/api"
  run ddev angular describe
  assert_failure
  assert_output --partial "is not reciprocal"
}

@test "auto-connect creates independent frontend placeholders" {
  cd "${SURFACE_TEST_ROOT}"
  mkdir auto
  cd auto
  ddev config --project-name="isolated-api" --project-type=laravel --project-tld=ddev.site
  printf 'additional_hostnames:\n    - isolated-api-local\n' > .ddev/config.host.local.yaml
  ddev add-on get "${DIR}"

  run ddev surface auto-connect
  assert_success
  assert_file_contains ".ddev/connections/app" "isolated-app"
  assert_file_contains ".ddev/connections/angular" "isolated-angular"
  assert_file_contains ".ddev/connections/admin" "isolated-admin"
  assert_file_contains ".ddev/connections/shop" "isolated-shop"

  ddev delete -Oy isolated-api >/dev/null 2>&1 || true
}

# bats test_tags=release
@test "install from release" {
  run ddev add-on get "${GITHUB_REPO}"
  assert_success

  health_checks
}
