#/usr/bin/env bash
for i in `seq 10`; do echo "hello$i" | ./kafka-console-producer-alpha.sh -topic topic.default1; done
