# Test-only SSH server (bastion + internal server). Never expose beyond 127.0.0.1.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server iproute2 \
    && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd \
    && rm -f /etc/ssh/ssh_host_*    # host keys are generated per container at start
RUN useradd -m -s /bin/bash jena && echo 'jena:jena-test' | chpasswd
RUN printf '%s\n' \
    'PasswordAuthentication yes' \
    'KbdInteractiveAuthentication yes' \
    'UsePAM yes' \
    'AllowTcpForwarding yes' > /etc/ssh/sshd_config.d/test.conf
EXPOSE 22
# Fresh host keys per container so "host key changed" (AC-6) can be tested by recreating one.
CMD ["sh", "-c", "ssh-keygen -A >/dev/null && exec /usr/sbin/sshd -D -e"]
