#!/bin/bash
# Compiles core + tests with Gradle's bundled Kotlin compiler and runs JUnit.
L=/opt/gradle-8.14.3/lib
CP=$(ls $L/*.jar | tr '\n' ':')
rm -rf /tmp/lhout && mkdir -p /tmp/lhout
cd "$(dirname "$0")/.."
java -cp "$CP" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -nowarn -cp "$L/kotlin-stdlib-2.0.21.jar:$L/junit-4.13.2.jar:$L/hamcrest-core-1.3.jar" -d /tmp/lhout app/src/main/java/com/hatdagger/localhero/core app/src/test/java 2>&1 | grep -v "Picked up"
java -cp "/tmp/lhout:$L/kotlin-stdlib-2.0.21.jar:$L/junit-4.13.2.jar:$L/hamcrest-core-1.3.jar" org.junit.runner.JUnitCore com.hatdagger.localhero.core.CoreTest 2>&1 | grep -v "Picked up" | grep -v -E "^\s+at (org.junit|java|jdk|sun)"
