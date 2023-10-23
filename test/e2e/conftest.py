import logging
from datetime import datetime

import allure
import pytest
from PIL import ImageGrab

import configs
import driver
from configs.system import IS_LIN
from fixtures.path import generate_test_info
from scripts.utils import local_system
from scripts.utils.system_path import SystemPath

_logger = logging.getLogger(__name__)

pytest_plugins = [
    'fixtures.aut',
    'fixtures.path',
    'fixtures.squish',
    'fixtures.testrail',
]


@pytest.fixture(scope='session', autouse=True)
def setup_session_scope(
        init_testrail_api,
        prepare_test_directory,
        start_squish_server,
):
    yield


@pytest.fixture(autouse=True)
def setup_function_scope(
        caplog,
        generate_test_data,
        check_result,
        application_logs
):
    caplog.set_level(configs.LOG_LEVEL)
    yield


@pytest.hookimpl(tryfirst=True, hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    rep = outcome.get_result()
    setattr(item, 'rep_' + rep.when, rep)


def pytest_exception_interact(node):
    try:
        test_path, test_name, test_params = generate_test_info(node)
        node_dir: SystemPath = configs.testpath.RUN / test_path / test_name / test_params
        node_dir.mkdir(parents=True, exist_ok=True)

        screenshot = node_dir / 'screenshot.png'
        if screenshot.exists():
            screenshot = node_dir / f'screenshot_{datetime.now():%H%M%S}.png'
        ImageGrab.grab(xdisplay=":0" if IS_LIN else None).save(screenshot)
        allure.attach(
            name='Screenshot on fail',
            body=screenshot.read_bytes(),
            attachment_type=allure.attachment_type.PNG)
    except Exception as ex:
        _logger.debug(ex)