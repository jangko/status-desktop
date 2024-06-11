import logging
import os
import signal
import subprocess
import time
import typing

import allure
import psutil

import configs
from configs.system import IS_WIN

LOG = logging.getLogger(__name__)


def find_process_by_port(port: int) -> typing.List[int]:
    pid_list = []
    for proc in psutil.process_iter():
        try:
            for conns in proc.connections(kind='inet'):
                if conns.laddr.port == port:
                    pid_list.append(proc.pid)
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            pass
    return pid_list


def find_free_port(start: int, step: int):
    while find_process_by_port(start):
        start += step
    return start


@allure.step('Kill process')
def kill_process(pid, sig: signal.Signals = signal.SIGKILL):
    LOG.debug('Sending %s to %d process', sig.name, pid)
    try:
        p = psutil.Process(pid)

    except ProcessLookupError as err:
        LOG.error('Failed to find process %d: %s', pid, err)
        raise err
    for i in range(2):
        try:
            LOG.warning('Waiting for process to exit: %d', pid)
            p.kill()
            if not p.is_running():
                break
        except RuntimeError:
            raise ('Failed to kill process: %d' % pid)


@allure.step('System execute command')
def execute(
        command: list,
        stderr=subprocess.STDOUT,
        stdout=subprocess.STDOUT,
        shell=False,
):
    LOG.info('Executing: %s', command)
    process = subprocess.Popen(command, shell=shell, stderr=stderr, stdout=stdout)
    return process.pid


@allure.step('System run command')
def run(
        command: list,
        stderr=subprocess.STDOUT,
        stdout=subprocess.STDOUT,
        shell=False,
        timeout_sec=configs.timeouts.PROCESS_TIMEOUT_SEC
):
    LOG.info('Running: %s', command)
    process = subprocess.run(
        command,
        shell=shell,
        stderr=stderr,
        stdout=stdout,
        timeout=timeout_sec,
        check=True
    )
