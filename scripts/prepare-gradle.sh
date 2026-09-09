#!/usr/bin/env bash
#
# Write the init script that applies the Codiqo Gradle plugin to the analysed build without
# editing any of its build files, and force-applies jacoco to every java subproject.
#
# The init script is generated rather than shipped so the plugin coordinate always matches the
# codiqo-version the rest of the run uses; a checked-in copy would drift the moment either side
# moved. It lands in the work directory, outside the repository, so the analysed checkout stays
# byte-identical to what actions/checkout produced — the per-commit loop relies on that.
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$GITHUB_ACTION_PATH/scripts/lib.sh"

init_script="$CODIQO_WORK_DIR/codiqo.init.gradle"
repo_url="${CODIQO_IN_PLUGIN_REPOSITORY_URL:-https://central.sonatype.com/repository/maven-snapshots}"

#
# Same rule as the Maven side: a -SNAPSHOT plugin is not on Maven Central proper, so the snapshot
# repository is added for it and only for it unless the caller overrides the decision.
#
case "${CODIQO_IN_MANAGE_PLUGIN_REPOSITORY:-auto}" in
    always) manage="yes" ;;
    never) manage="no" ;;
    auto)
        manage="no"
        case "${CODIQO_IN_VERSION}" in
            *-SNAPSHOT) manage="yes" ;;
        esac
        ;;
    *) codiqo::die "manage-plugin-repository must be auto, always or never, got '${CODIQO_IN_MANAGE_PLUGIN_REPOSITORY}'." ;;
esac

managed_repo=""
freshness=""
if [ "$manage" = "yes" ]; then
    managed_repo="        maven { url = uri('${repo_url}') }"
    codiqo::log "adding ${repo_url} to the init script's plugin classpath repositories."

    #
    # A snapshot is a changing module, and Gradle caches one for 24 hours — while a copy picked up
    # from mavenLocal() is never freshness-checked at all. The Maven path passes -U on every
    # invocation, so without this the two tools would analyse the same commit with plugins built a
    # day apart, and the version string in the summary would read 1.0-SNAPSHOT either way. Scoped
    # to the initscript classpath, so the analysed project's own dependencies are untouched.
    #
    freshness="    configurations.classpath {
        resolutionStrategy.cacheChangingModulesFor 0, 'seconds'
        resolutionStrategy.cacheDynamicVersionsFor 0, 'seconds'
    }"
fi

#
# Codiqo owns coverage in the analysis build, so jacoco is applied whether or not the project uses
# it: the plugin then normalises every Test task's exec file, and the analysis reads a uniform
# per-module location instead of whatever the project happened to configure. With ignore-coverage
# there is no coverage to read, so instrumenting every test JVM would be pure cost.
#
jacoco_block="
allprojects { project ->
    project.pluginManager.withPlugin('java') {
        project.pluginManager.apply('jacoco')
    }
}"
if [ "${CODIQO_IN_IGNORE_COVERAGE:-false}" = "true" ]; then
    jacoco_block=""
    codiqo::log "ignore-coverage is set: leaving jacoco out of the init script."
fi

mkdir -p "$CODIQO_WORK_DIR"
cat > "$init_script" <<EOF
initscript {
    repositories {
        mavenLocal()
        mavenCentral()
${managed_repo}
    }
    dependencies {
        classpath 'io.codiqo:codiqo-gradle-plugin:${CODIQO_IN_VERSION}'
    }
${freshness}
}

rootProject {
    apply plugin: io.codiqo.gradle.CodiqoGradlePlugin
}
${jacoco_block}
EOF

codiqo::export CODIQO_GRADLE_INIT "$init_script"
codiqo::log "wrote the Codiqo init script to $init_script"
