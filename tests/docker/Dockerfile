# Test-only SSH server (bastion + internal server). Never expose beyond 127.0.0.1.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server openssh-sftp-server iproute2 locales \
    && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd \
    && rm -f /etc/ssh/ssh_host_*    # host keys are generated per container at start
# Like typical servers: UTF-8 locales exist, and sshd accepts LANG (Debian default AcceptEnv).
RUN sed -i -e 's/^# *ko_KR.UTF-8/ko_KR.UTF-8/' -e 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen >/dev/null
RUN useradd -m -s /bin/bash jena && echo 'jena:jena-test' | chpasswd
# Password must be changed at next login (기획서 FR-03b): SFTP fails, a PTY shell asks for a new one.
RUN useradd -m -s /bin/bash expired && echo 'expired:old-pass-1' | chpasswd && chage -d 0 expired
RUN printf '%s\n' \
    'PasswordAuthentication yes' \
    'KbdInteractiveAuthentication yes' \
    'UsePAM yes' \
    'AllowTcpForwarding yes' > /etc/ssh/sshd_config.d/test.conf
EXPOSE 22
# Fresh host keys per container so "host key changed" (AC-6) can be tested by recreating one.
CMD ["sh", "-c", "ssh-keygen -A >/dev/null && exec /usr/sbin/sshd -D -e"]
