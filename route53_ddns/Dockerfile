ARG BUILD_FROM
FROM ${BUILD_FROM}

RUN pip3 install --no-cache-dir boto3

COPY run.sh /
RUN chmod a+x /run.sh

CMD ["/run.sh"]
