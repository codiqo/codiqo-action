#!/usr/bin/env bash
#
# Resolve the codiqo-maven-time-machine core extension and export its classpath.
#
# Why the host Maven needs it: analysing a historical commit means building POMs as they were
# at that moment. Without the extension, a -SNAPSHOT parent or imported BOM resolves to the
# LATEST deploy, so a dependency that was removed later makes the historical commit fail as a
# "broken POM" before analysis even starts. Maven loads core extensions only at bootstrap,
# which is why this has to arrive via -Dmaven.ext.class.path rather than plugin configuration.
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$GITHUB_ACTION_PATH/scripts/lib.sh"

ext_pom="$CODIQO_WORK_DIR/tm-ext-pom.xml"
ext_cp="$CODIQO_WORK_DIR/tm-ext-cp.txt"
repo_url="${CODIQO_IN_PLUGIN_REPOSITORY_URL:-https://central.sonatype.com/repository/maven-snapshots}"

{
    cat << XML
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>io.codiqo.ci</groupId>
  <artifactId>codiqo-tm-ext</artifactId>
  <version>1</version>
  <packaging>pom</packaging>
  <dependencies>
    <dependency>
      <groupId>io.codiqo</groupId>
      <artifactId>codiqo-maven-time-machine</artifactId>
      <version>${CODIQO_IN_VERSION}</version>
    </dependency>
  </dependencies>
  <repositories>
    <repository>
      <id>central-snapshots</id>
      <url>${repo_url}</url>
      <releases><enabled>false</enabled></releases>
      <snapshots><enabled>true</enabled></snapshots>
    </repository>
XML
    #
    # Extra repositories let a caller with a private registry resolve the extension from it.
    # Credentials come from settings-xml, matched by repository id.
    #
    if [ -n "${CODIQO_IN_TIME_MACHINE_REPOSITORIES:-}" ]; then
        printf '%s\n' "${CODIQO_IN_TIME_MACHINE_REPOSITORIES}" | while IFS= read -r line; do
            trimmed="${line#"${line%%[![:space:]]*}"}"
            trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
            case "$trimmed" in '' | '#'*) continue ;; esac
            case "$trimmed" in
                *=*) : ;;
                *)
                    printf '::error::time-machine-repositories line %s is not id=url\n' "$trimmed" >&2
                    exit 1
                    ;;
            esac
            printf '    <repository><id>%s</id><url>%s</url><releases><enabled>true</enabled></releases><snapshots><enabled>true</enabled></snapshots></repository>\n' \
                "${trimmed%%=*}" "${trimmed#*=}"
        done
    fi
    printf '  </repositories>\n</project>\n'
} > "$ext_pom"

codiqo::read_lines_into extra_args "$CODIQO_WORK_DIR/mvn-args"
codiqo::read_lines_into user_props "$CODIQO_WORK_DIR/mvn-props"

cmd=("$CODIQO_MVN" -B -ntp -e -U)
cmd+=(${extra_args[@]+"${extra_args[@]}"})
cmd+=(${user_props[@]+"${user_props[@]}"})
cmd+=(-f "$ext_pom" dependency:build-classpath -DincludeScope=runtime "-Dmdep.outputFile=$ext_cp")

rc=0
codiqo::run_maven_step "codiqo-time-machine" "${cmd[@]}" || rc=$?
codiqo::emit_log_warnings "$CODIQO_LOGS_DIR/codiqo-time-machine.log"

#
# This is a hard failure on purpose. The plugin resolves the same artifact itself, unguarded
# (unlike its optional extensions), so a run that continued here would fail on every commit
# with a far less obvious message.
#
if ! reason=$(codiqo::assert_build_success "$CODIQO_LOGS_DIR/codiqo-time-machine.log" "$rc"); then
    codiqo::error "could not resolve io.codiqo:codiqo-maven-time-machine:${CODIQO_IN_VERSION} — it $reason."
    codiqo::log "repositories tried: ${repo_url}${CODIQO_IN_TIME_MACHINE_REPOSITORIES:+, plus time-machine-repositories}"
    codiqo::log "fixes: point codiqo-version at a version your repositories carry, add the repository via settings-xml or time-machine-repositories."
    codiqo::log "note: time-machine: false does NOT avoid this — the plugin resolves the artifact regardless; the toggle only skips the host classpath."
    codiqo::tail_log "$CODIQO_LOGS_DIR/codiqo-time-machine.log"
    exit 1
fi

if [ ! -s "$ext_cp" ]; then
    codiqo::die "dependency:build-classpath produced no classpath at $ext_cp."
fi

codiqo::export CODIQO_TM_EXT_CLASSPATH "$(tr -d '\r\n' < "$ext_cp")"
codiqo::log "time-machine extension classpath resolved ($(wc -c < "$ext_cp" | tr -d ' ') bytes)."
