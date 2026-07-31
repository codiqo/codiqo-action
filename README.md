# Codiqo Analyze

Measure the engineering effort behind your commits. For every commit that has not been analysed
yet, this action builds the project as it was at that commit, resolves the call graph of the code
that changed, and submits the result to [Codiqo](https://codiqo.io).

Because it replays each commit's own build, the analysis reflects what the change actually touched
rather than a count of diff lines.

## Quick start

Add your API key as a repository secret named `CODIQO_API_KEY`, then add
`.github/workflows/codiqo.yml`:

```yaml
name: Codiqo

on:
  schedule:
    - cron: '0 * * * *'
  workflow_dispatch:

concurrency:
  group: codiqo
  cancel-in-progress: false

jobs:
  analyze:
    runs-on: ubuntu-latest
    timeout-minutes: 360
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0          # required, see Requirements

      - uses: codiqo/codiqo-action@main
        with:
          api-key: ${{ secrets.CODIQO_API_KEY }}
```

The action is incremental: commits already scored are skipped, so a schedule simply catches up.

## Requirements

- **A Maven project.** Gradle is not supported.
- **A Linux runner.** The status heartbeat reads `/proc` and the per-commit deadline uses GNU
  `timeout`. Other platforms degrade rather than fail, but are untested.
- **Full git history** — `fetch-depth: 0`. Codiqo walks history to find commits needing analysis
  and skips any commit whose parent is missing locally, so a shallow clone yields a run that
  succeeds having analysed nothing. The action refuses to start on a shallow or partially-cloned
  repository; set `require-full-history: false` if you accept that consequence.
- **A JDK that can build your project**, and Java 21 or newer for the language server. Set
  `java-version` accordingly, or `''` to manage the JDK yourself.
- **Time.** Each commit runs a full `clean verify`. Give the job a generous `timeout-minutes`, cap
  the first run with `max-commits-per-run`, and consider `ignore-coverage: true` while trialling.

## Inputs

### Identity and authentication

| Input | Default | Description |
| --- | --- | --- |
| `api-key` | — (required) | Codiqo API key. Reaches Maven by environment reference, never on the command line. |
| `api-url` | `https://api.codiqo.io` | Override only for a self-hosted backend. |
| `branch` | `''` | Branch to attribute the index to. Empty derives it from the event; the head branch is used for pull requests. |

### Versions and tooling

| Input | Default | Description |
| --- | --- | --- |
| `codiqo-version` | `1.0-SNAPSHOT` | Plugin version. Codiqo is pre-1.0, so a snapshot repository is added automatically. |
| `java-version` | `21` | JDK to install. `''` skips JDK setup entirely. |
| `java-distribution` | `temurin` | Passed to `actions/setup-java`. |
| `java-home` | `''` | Explicit JDK for the per-commit build and language server. |
| `maven-command` | `auto` | `auto` prefers `./mvnw`, else `mvn`. This action does not install Maven. |
| `maven-home` | `''` | Maven home for the forked build. |
| `jdtls-version` | `''` | Language server version override. |
| `cache` | `maven` | `actions/setup-java` cache. Set `''` to disable. |

### Scope and filters

| Input | Default | Description |
| --- | --- | --- |
| `commit-window` | `3m` | `0`, `1m`, `3m`, `6m`, `1year`, or a raw ISO-8601 period such as `P2W`. |
| `exclude-author-emails` | `''` | Comma-separated; a trailing `*` is allowed, e.g. `bot@*`. |
| `include-author-emails` | `''` | Restrict analysis to these authors. |
| `first-parent-only` | `true` | Measure a merge as what it brought to the target branch. |
| `max-commits-per-run` | `1024` | Upper bound per run. Lower it for a first adoption. |
| `index-batch-size` | `200` | Commits per index request. |

### Timeouts

| Input | Default | Description |
| --- | --- | --- |
| `per-commit-timeout` | `1h` | `30m`, `1h`, `90m`, `2h`, or raw minutes. Keep above `build-timeout-minutes`. |
| `build-timeout-minutes` | `60` | Forked build of one commit. |
| `test-timeout-minutes` | `30` | Test phase of the forked build. |
| `per-test-timeout` | `15m` | One JUnit 5 test method; `off` disables. Capped at 15 minutes. |
| `import-timeout-minutes` | `15` | Language server project import. Raise for a large reactor. |
| `api-connect-timeout-seconds` | `30` | |
| `api-read-timeout-seconds` | `60` | |

`per-commit-timeout-minutes` is deprecated; `per-commit-timeout` accepts plain minutes.

### Maven wiring

| Input | Default | Description |
| --- | --- | --- |
| `settings-xml` | `''` | Complete `settings.xml` content, written to `~/.m2/settings.xml`. |
| `maven-user-properties` | `''` | Newline `key=value`, passed as `-Dkey=value`. Never secrets. |
| `maven-args` | `''` | Extra arguments, one per line. |
| `maven-opts` | `''` | `MAVEN_OPTS`. The forked build inherits it. |
| `maven-parallelism` | `''` | `-T` value, e.g. `1C`. Propagates into the forked build. |
| `manage-plugin-repository` | `auto` | `auto` (snapshot versions only), `always`, `never`. |
| `plugin-repository-url` | Central snapshots | Where the plugin and its extension are resolved from. |
| `time-machine-repositories` | `''` | Extra `id=url` lines for resolving the extension privately. |

### Behaviour

| Input | Default | Description |
| --- | --- | --- |
| `score-on-build-failure` | `false` | Score from the diff alone when a build fails, instead of excluding the commit. |
| `exclude-reverted-commits` | `true` | Analysing a revert also retroactively excludes what it reverted, so reverted work stops counting. |
| `ignore-coverage` | `false` | Skip tests in the forked build. Much faster, no coverage data. |
| `time-machine` | `true` | Resolve a historical commit's snapshot dependencies as of that commit. |
| `dump-analysis` | `true` | Keep the analysis document for debugging. |
| `fail-fast` | `true` | Stop at the first failing commit. |
| `require-full-history` | `true` | Refuse to run on a shallow or filtered clone. |

### Observability

| Input | Default | Description |
| --- | --- | --- |
| `heartbeat-interval-seconds` | `30` | Status line cadence while Maven runs into its log. |
| `maven-step-tail-lines` | `400` | Log lines echoed on failure. |
| `upload-logs` | `true` | Upload logs as an artifact. |
| `log-artifact-name` | `codiqo-analyze-logs` | Must be unique within a workflow run. |
| `log-retention-days` | `7` | |
| `redact-env-names` | `''` | Env var names whose values are scrubbed from logs before upload. |
| `log-commit-authors` | `false` | Include author names and emails in the log. |

## Outputs

| Output | Description |
| --- | --- |
| `missing-count` | Commits that needed analysis. |
| `analysed-count` | Commits analysed and submitted successfully. |
| `failed-count` | Commits that failed. |
| `missing-file` | Path to the list of pending commits, oldest first. |
| `logs-dir` | Directory holding the step and per-commit logs. |

## Private repositories

Pass a complete `settings.xml` through `settings-xml`, and any properties your POMs interpolate
through `maven-user-properties`:

```yaml
      - uses: codiqo/codiqo-action@main
        with:
          api-key: ${{ secrets.CODIQO_API_KEY }}
          maven-user-properties: |
            my.registry.url=${{ vars.REGISTRY_URL }}
          settings-xml: |
            <settings>
              <servers>
                <server>
                  <id>my-registry</id>
                  <username>${{ secrets.REGISTRY_USER }}</username>
                  <password><![CDATA[${{ secrets.REGISTRY_TOKEN }}]]></password>
                </server>
              </servers>
              <profiles>
                <profile>
                  <id>my-registry</id>
                  <properties>
                    <my.registry.url>${{ vars.REGISTRY_URL }}</my.registry.url>
                  </properties>
                  <repositories>
                    <repository>
                      <id>my-registry</id>
                      <url>${{ vars.REGISTRY_URL }}</url>
                      <releases><enabled>true</enabled></releases>
                      <snapshots><enabled>true</enabled></snapshots>
                    </repository>
                  </repositories>
                  <pluginRepositories>
                    <pluginRepository>
                      <id>my-registry</id>
                      <url>${{ vars.REGISTRY_URL }}</url>
                      <releases><enabled>true</enabled></releases>
                      <snapshots><enabled>true</enabled></snapshots>
                    </pluginRepository>
                  </pluginRepositories>
                </profile>
              </profiles>
              <activeProfiles>
                <activeProfile>my-registry</activeProfile>
              </activeProfiles>
            </settings>
          redact-env-names: REGISTRY_TOKEN
```

Four details matter, and every one of them has caused a silent failure in practice:

1. **The settings file must be at the default location.** The action writes it to
   `~/.m2/settings.xml`, because Codiqo's language server runs an embedded m2e in a separate
   process that reads only that path. `-s /some/other/settings.xml` never reaches it.
2. **Declare both `<repositories>` and `<pluginRepositories>`.** Codiqo resolves its own helper
   artifacts from the union of the two lists.
3. **Put registry properties in a `<profile><properties>` block**, not only in
   `maven-user-properties`. The forked per-commit build does not inherit the host's `-D`
   properties, and neither does m2e; an active profile is the only channel that reaches both.
4. **The parent POM must be resolvable from `settings.xml` alone.** Maven resolves a POM's parent
   *before* it can read that POM's own `<repositories>`.

Get any of these wrong and the analysis still completes — but with **zero callers** and an
understated blast radius, because the language server silently ended up with no Java model.

## How it works

1. **Index.** `index-commits` reports which commits within `commit-window` still need analysis,
   **oldest first**, capped at `max-commits-per-run`.
2. **Time machine.** The Codiqo core extension is resolved and placed on the host Maven's
   extension classpath, so a historical commit resolves the snapshot dependencies it had at the
   time rather than today's. Without it, a `dependencyManagement` entry removed later makes an old
   commit fail as a broken POM before analysis starts.
3. **Submit.** Each commit is analysed in turn under its own deadline: the project is built,
   coverage and static analysis are collected, the call graph is resolved, and the result is
   submitted. Commits run sequentially on purpose — two full builds plus two language servers on
   one runner produce timeouts that look like build failures.

## Logs and secrets

Every Maven invocation writes to its own file under `${{ runner.temp }}/step-logs/`, uploaded as
an artifact. A status line prints on a heartbeat so a long job stays visibly alive, and warning and
error lines are echoed back into the live log.

GitHub masks registered secrets in the **live** log only — artifact bytes are uploaded verbatim.
List any sensitive environment variable in `redact-env-names` and the action scrubs its value, its
base64 form, and its `user:value` Basic-auth form before upload. `api-key` and `settings-xml` are
always scrubbed. Commit author identity is excluded by default; set `log-commit-authors: true` if
you want it.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| **Zero callers, external impact "none"** | `settings.xml` is not at `~/.m2/settings.xml`, or m2e cannot resolve your parent POMs. See the four details above. |
| `repository has incomplete history` | Add `fetch-depth: 0` to `actions/checkout`. |
| `0 commits require analysis`, unexpectedly | Widen `commit-window`, check `exclude-author-emails`, confirm full history. |
| **Plugin or `codiqo-maven-time-machine` will not resolve** | The version is not in your repositories. Check `codiqo-version`; note that a catch-all `<mirrorOf>` swallows the snapshot repository — exclude it with `<mirrorOf>external:*,!central-snapshots</mirrorOf>`. |
| **Commit killed at the deadline** | Raise `per-commit-timeout` and `build-timeout-minutes`. Exit 137 can also be a kernel OOM kill: lower `maven-parallelism` or use a larger runner. |
| **Artifact name conflict** | Give each job a distinct `log-artifact-name`. |

## Versioning

**No release exists yet.** This action is pre-1.0 and still moving, so `@main` is currently the
only ref that resolves — it is the equivalent of depending on a snapshot.

| Ref | Use it for | Stability |
| --- | --- | --- |
| `@main` | Everything today. Resolved at job start, so each push is live immediately. | None. May break without warning. |
| `@<sha>` | Reproducing an exact run, or insulating one repository from `main` moving. | Immutable. |
| `@v0` | Not available yet. Appears with the first `v0.x.y` tag and then tracks it. | Inputs may change between minors. |
| `@v1` | Not available yet. Waits until the input surface stops changing. | `v1` moves across `v1.x.y`; breaking changes go to `v2`. |

Two consequences of `@main` worth knowing. A push mid-run means two jobs in the same workflow run
can execute different code, because the branch is resolved per job. And a broken `main` breaks every
consumer at once — which is precisely why `.github/workflows/ci.yml` gates it.

When you want a release, push a tag: `v0.1.0` publishes a pre-release and points `v0` at it. The
machinery is already in `.github/workflows/release.yml`; nothing needs adding.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
