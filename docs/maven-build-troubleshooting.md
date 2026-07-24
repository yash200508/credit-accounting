# Maven Build Troubleshooting

This project uses Maven, but the current Codex/cloud container cannot reach Maven Central through its configured proxy. The failure happens before project compilation while Maven resolves standard plugins such as `maven-resources-plugin`.

## What was checked

- No Maven wrapper files (`mvnw`, `mvnw.cmd`, or `.mvn/wrapper/maven-wrapper.properties`) are currently present.
- The global Maven settings in the container use an HTTP proxy at `proxy:8080`.
- A direct request to Maven Central through that proxy returns HTTP `403 Forbidden`.
- Bypassing the proxy fails DNS resolution for `repo.maven.apache.org` inside this container.

## Would adding Maven Wrapper fix this?

Not by itself. Maven Wrapper helps standardize the Maven version, but it still needs network access to download the Maven distribution and Maven still needs repository access to resolve plugins and dependencies. In this environment, repository access is blocked before compilation, so adding wrapper files would not fix the current `403 Forbidden` blocker.

A wrapper can still be added later from a trusted environment if the project wants a pinned Maven version for developers and CI.

## Safe mirror/cache configuration

If your organization has a Nexus, Artifactory, or other Maven cache, configure it outside this repository in your user-level or CI-level Maven settings file.

1. Copy `docs/maven-settings-template.xml` to `~/.m2/settings.xml` or to a CI secret-managed settings file.
2. Replace the example URL with your approved mirror/cache URL.
3. Keep credentials in environment variables or the CI secret manager.
4. Do not commit private URLs, usernames, passwords, tokens, or `.env` files.

## Commands to retry after Maven access is fixed

```bash
mvn test
mvn -DskipTests package
```

## Temporary local smoke-test workaround

Until Maven repository access works, run the dependency-free smoke test documented in `README.md`:

```bash
mkdir -p target/smoke-tests
javac -encoding UTF-8 -cp src/main/java -d target/smoke-tests src/test/java/com/gasstation/app/BusinessLogicSmokeTest.java
java -cp target/smoke-tests:src/main/java com.gasstation.app.BusinessLogicSmokeTest
```
