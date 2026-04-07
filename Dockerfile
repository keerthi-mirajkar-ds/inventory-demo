FROM public.ecr.aws/amazoncorretto/amazoncorretto:17
WORKDIR /app
ARG JAR_FILE=target/app.jar
COPY ${JAR_FILE} app.jar
EXPOSE 8080
ENTRYPOINT ["java","-jar","app.jar"]
