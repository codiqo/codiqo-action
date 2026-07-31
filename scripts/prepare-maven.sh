#!/usr/bin/env bash
#
# Put Maven settings in place.
#
# The file MUST land at ~/.m2/settings.xml and nowhere else. Codiqo starts the Eclipse JDT
# language server to build the call graph, and its embedded m2e is a separate process that
# reads only the default settings location — `-s /some/other/settings.xml` never reaches it.
# When m2e cannot resolve a project's parent POM the import fails, the workspace ends up
# with no Java model, every call-hierarchy query answers null, and the analysis reports zero
# callers while otherwise looking perfectly healthy.
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$GITHUB_ACTION_PATH/scripts/lib.sh"

settings_dir="$HOME/.m2"
settings_file="$settings_dir/settings.xml"
mkdir -p "$settings_dir"

if [ -n "${CODIQO_IN_SETTINGS_XML:-}" ]; then
    if [ -f "$settings_file" ]; then
        cp "$settings_file" "$CODIQO_WORK_DIR/settings.xml.bak"
        codiqo::warn "overwriting an existing $settings_file (backed up to $CODIQO_WORK_DIR/settings.xml.bak). If a previous step ran setup-java with server-id, that is where the original came from."
    fi
    #
    # printf, not a heredoc: the reference implementation used an unquoted `cat <<EOF`, which
    # would mangle or execute a credential containing backticks or $(...).
    #
    printf '%s\n' "${CODIQO_IN_SETTINGS_XML}" > "$settings_file"
    chmod 600 "$settings_file"
    codiqo::log "wrote $settings_file from the settings-xml input ($(wc -c < "$settings_file" | tr -d ' ') bytes)."
fi

#
# Decide whether to add a repository that can serve the plugin itself. `auto` only acts for a
# -SNAPSHOT plugin version, which Maven Central proper does not carry.
#
inject="no"
case "${CODIQO_IN_MANAGE_PLUGIN_REPOSITORY:-auto}" in
    never) inject="no" ;;
    always) inject="yes" ;;
    auto | '')
        case "${CODIQO_IN_VERSION:-}" in
            *-SNAPSHOT) inject="yes" ;;
        esac
        ;;
    *) codiqo::die "manage-plugin-repository must be auto, always or never, got '${CODIQO_IN_MANAGE_PLUGIN_REPOSITORY}'." ;;
esac

repo_url="${CODIQO_IN_PLUGIN_REPOSITORY_URL:-https://central.sonatype.com/repository/maven-snapshots}"

if [ "$inject" = "yes" ]; then
    if [ ! -f "$settings_file" ]; then
        #
        # Both <repositories> and <pluginRepositories> are required, not one or the other: the
        # plugin resolves its own helper artifacts (the time-machine core extension and the
        # Lombok agent) from the union of the project and plugin repository lists.
        #
        cat > "$settings_file" << XML
<settings>
  <profiles>
    <profile>
      <id>codiqo-managed-repos</id>
      <repositories>
        <repository>
          <id>central-snapshots</id>
          <url>${repo_url}</url>
          <releases><enabled>false</enabled></releases>
          <snapshots><enabled>true</enabled><updatePolicy>always</updatePolicy></snapshots>
        </repository>
      </repositories>
      <pluginRepositories>
        <pluginRepository>
          <id>central-snapshots</id>
          <url>${repo_url}</url>
          <releases><enabled>false</enabled></releases>
          <snapshots><enabled>true</enabled><updatePolicy>always</updatePolicy></snapshots>
        </pluginRepository>
      </pluginRepositories>
    </profile>
  </profiles>
  <activeProfiles>
    <activeProfile>codiqo-managed-repos</activeProfile>
  </activeProfiles>
</settings>
XML
        chmod 600 "$settings_file"
        codiqo::log "generated $settings_file with a snapshot repository for ${CODIQO_IN_VERSION:-the plugin}."
    else
        if python3 "$GITHUB_ACTION_PATH/scripts/inject-plugin-repository.py" "$settings_file" "$repo_url"; then
            :
        else
            codiqo::warn "could not merge a snapshot repository into $settings_file. If '${CODIQO_IN_VERSION:-}' fails to resolve, add this to an active profile yourself:
  <repository><id>central-snapshots</id><url>${repo_url}</url><snapshots><enabled>true</enabled></snapshots></repository>
  ... and the same under <pluginRepositories>."
        fi
    fi
fi

#
# A catch-all mirror silently swallows the snapshot repository, which then fails to resolve
# with a message that points at the wrong place. Warn rather than edit the caller's mirror.
#
if [ -f "$settings_file" ] && grep -qE '<mirrorOf>[[:space:]]*(\*|external:\*)[[:space:]]*</mirrorOf>' "$settings_file"; then
    codiqo::warn "settings.xml declares a catch-all <mirrorOf>. Snapshot and plugin resolution will be routed through that mirror; if resolution fails, exclude the snapshot repository, e.g. <mirrorOf>external:*,!central-snapshots</mirrorOf>."
fi
