# Java service (Maven, e.g. Spring Boot): JDK and Maven only in the build stage, JRE at runtime; UID 10001.
# CHANGE: Maven/JDK tag; keep the JDK major equal to the runtime JRE major
FROM maven:3.9.16-eclipse-temurin-25-noble AS build
WORKDIR /src
COPY pom.xml ./
RUN --mount=type=cache,target=/root/.m2 mvn -B -q dependency:go-offline
COPY src ./src
# Tests run in CI before the image build. cp fails on purpose if the build produces more than one jar.
# CHANGE: artifact path for multi-module builds
RUN --mount=type=cache,target=/root/.m2 mvn -B -q -DskipTests package \
 && cp target/*.jar /tmp/app.jar

# CHANGE: JRE tag
FROM eclipse-temurin:25.0.4.1_1-jre-noble
WORKDIR /app
COPY --from=build /tmp/app.jar /app/app.jar
# Heap follows the container limit; direct memory and metaspace are bounded so heap + off-heap stays under it
# (unset direct memory defaults to the max heap). Budget: skills/app-runtime/references/jvm-and-others.md.
# CHANGE: sized for a >= 2 GiB limit; at 512 MiB use MaxRAMPercentage=40, 64m direct, 128m metaspace
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=60 -XX:MaxDirectMemorySize=256m -XX:MaxMetaspaceSize=256m -XX:+ExitOnOutOfMemoryError"
USER 10001:10001
# CHANGE: listen port
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
