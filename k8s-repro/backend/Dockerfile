FROM eclipse-temurin:25-jdk-noble
WORKDIR /app
COPY target/app.jar app.jar

EXPOSE 8081

ENTRYPOINT ["java", "-jar", "app.jar"]
