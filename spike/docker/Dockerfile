# Test-only SSH server for the russh spike. Never expose outside localhost.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server openssh-sftp-server iproute2 \
    && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd
RUN useradd -m -s /bin/bash jena && echo 'jena:jena-test' | chpasswd
COPY spike_key.pub /home/jena/.ssh/authorized_keys
RUN chown -R jena:jena /home/jena/.ssh && chmod 700 /home/jena/.ssh && chmod 600 /home/jena/.ssh/authorized_keys
RUN printf '%s\n' \
    'PasswordAuthentication yes' \
    'KbdInteractiveAuthentication yes' \
    'UsePAM yes' \
    'AllowTcpForwarding yes' > /etc/ssh/sshd_config.d/spike.conf
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
