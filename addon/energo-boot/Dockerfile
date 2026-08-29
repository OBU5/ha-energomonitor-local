ARG BUILD_FROM
FROM ${BUILD_FROM}

RUN apk add --no-cache python3

COPY server.py /server.py
RUN chmod a+r /server.py

# -u is required: without unbuffered stdout the Supervisor add-on log stays empty
# until the buffer flushes, which makes debugging the handshake miserable.
CMD ["python3", "-u", "/server.py"]
