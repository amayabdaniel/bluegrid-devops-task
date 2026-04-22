# syntax=docker/dockerfile:1.10
ARG JAVA_VERSION=25
ARG ALPINE_VERSION=3.20

FROM eclipse-temurin:${JAVA_VERSION}-jdk-alpine AS build
WORKDIR /workspace

COPY app/.mvn .mvn
COPY app/mvnw app/pom.xml ./
RUN chmod +x mvnw
RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw -B -e -ntp dependency:go-offline

COPY app/src ./src
RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw -B -e -ntp clean verify && \
    cp target/gs-rest-service-*.jar /workspace/app.jar


FROM eclipse-temurin:${JAVA_VERSION}-jdk-alpine AS jre

# hadolint ignore=DL3018
RUN apk add --no-cache binutils && \
    "$JAVA_HOME/bin/jlink" \
      --add-modules \
        java.base,java.compiler,java.desktop,java.instrument,java.logging,\
java.management,java.management.rmi,java.naming,java.net.http,java.prefs,\
java.rmi,java.scripting,java.security.jgss,java.security.sasl,java.sql,\
java.sql.rowset,java.transaction.xa,java.xml,java.xml.crypto,jdk.crypto.cryptoki,\
jdk.crypto.ec,jdk.httpserver,jdk.jdi,jdk.management,jdk.management.agent,\
jdk.naming.dns,jdk.naming.rmi,jdk.net,jdk.unsupported,jdk.zipfs,jdk.localedata \
      --include-locales en \
      --no-header-files \
      --no-man-pages \
      --strip-debug \
      --compress=zip-9 \
      --output /opt/jre


FROM alpine:${ALPINE_VERSION} AS runtime

ARG ALPINE_VERSION
ARG APP_VERSION=0.1.0
ARG GIT_SHA=unknown

LABEL org.opencontainers.image.title="gs-rest-service" \
      org.opencontainers.image.description="Spring Boot REST service" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.base.name="docker.io/library/alpine:${ALPINE_VERSION}"

# hadolint ignore=DL3018
RUN apk add --no-cache tini tzdata ca-certificates && \
    addgroup -S -g 10001 app && \
    adduser  -S -u 10001 -G app -h /home/app -s /sbin/nologin app

ENV JAVA_HOME=/opt/jre \
    PATH=/opt/jre/bin:$PATH \
    JAVA_OPTS="-XX:MaxRAMPercentage=75 -XX:+UseSerialGC -XX:+ExitOnOutOfMemoryError -Djava.security.egd=file:/dev/./urandom" \
    SERVER_PORT=8080 \
    MANAGEMENT_PORT=8081 \
    SPRING_MAIN_BANNER_MODE=off

COPY --from=jre /opt/jre /opt/jre

WORKDIR /app
COPY --from=build --chown=app:app /workspace/app.jar /app/app.jar

EXPOSE 8080

USER 10001:10001

HEALTHCHECK --interval=15s --timeout=3s --start-period=25s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${MANAGEMENT_PORT}/actuator/health" 2>/dev/null | grep -q '"status":"UP"' || exit 1

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar --server.port=${SERVER_PORT} --management.server.port=${MANAGEMENT_PORT}"]
