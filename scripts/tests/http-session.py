#!/usr/bin/env python3
"""Exercise Laravel sessions, CSRF and Livewire against the disposable Compose stack."""
import http.cookiejar
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path


class Page(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.inputs = {}
        self.csrf = None
        self.search = None
        self.update_uri = None
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'input' and 'name' in attrs and attrs.get('type') != 'checkbox':
            self.inputs[attrs['name']] = attrs.get('value') or ''
        if tag == 'meta' and attrs.get('name') == 'csrf-token':
            self.csrf = attrs['content']
        if 'wire:snapshot' in attrs:
            snapshot = json.loads(attrs['wire:snapshot'])
            if snapshot['memo']['name'] == 'torrent-search':
                self.search = attrs['wire:snapshot']
        if 'data-update-uri' in attrs:
            self.update_uri = attrs['data-update-uri']

    def handle_data(self, data):
        # UNIT3D bundles Livewire through Vite and emits @livewireScriptConfig.
        prefix = 'window.livewireScriptConfig = '
        if data.strip().startswith(prefix):
            config = json.loads(data.strip()[len(prefix):].removesuffix(';'))
            self.update_uri = config['uri']


base = sys.argv[1].rstrip('/')
assert urllib.parse.urlsplit(base).hostname in ('127.0.0.1', 'localhost'), 'Local fixture only'


def local_url(url):
    parts = urllib.parse.urlsplit(urllib.parse.urljoin(base + '/', url))
    assert parts.hostname in ('127.0.0.1', 'localhost'), 'Unexpected external redirect'
    # APP_URL is localhost, while Compose publishes a random loopback port.
    return base + urllib.parse.urlunsplit(('', '', parts.path, parts.query, ''))


class LocalRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return super().redirect_request(req, fp, code, msg, headers, local_url(newurl))


client = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()), LocalRedirects())


def request(path, data=None, headers=None):
    req = urllib.request.Request(local_url(path), data=data, headers=headers or {})
    with client.open(req, timeout=30) as response:
        return response.url, response.read().decode()


fixtures = dict(line.split('=', 1) for line in Path('compose/.env.test').read_text().splitlines()
                if line.startswith('DEFAULT_OWNER_'))
url, html = request('/login')
login = Page(html)
assert login.csrf and '_token' in login.inputs, 'Login CSRF token missing'
login.inputs.update(username=fixtures['DEFAULT_OWNER_NAME'],
                    password=fixtures['DEFAULT_OWNER_PASSWORD'])
url, _ = request('/login', urllib.parse.urlencode(login.inputs).encode(),
                 {'Content-Type': 'application/x-www-form-urlencoded'})
assert urllib.parse.urlsplit(url).path != '/login', 'Owner login failed'
url, html = request('/torrents')
assert urllib.parse.urlsplit(url).path == '/torrents', 'Authenticated session lost'
page = Page(html)
assert page.csrf and page.search and page.update_uri, 'Livewire search did not render'
payload = {'_token': 'invalid-test-token', 'components': [
    {'snapshot': page.search, 'updates': {'name': 'Debian ISO'}, 'calls': []}]}
headers = {'Content-Type': 'application/json', 'Accept': 'application/json', 'X-Livewire': 'true'}
try:
    request(page.update_uri, json.dumps(payload).encode(), headers)
except urllib.error.HTTPError as error:
    assert error.code == 419, f'Expected CSRF rejection, received HTTP {error.code}'
else:
    raise AssertionError('Livewire accepted an invalid CSRF token')
payload['_token'] = page.csrf
_, result = request(page.update_uri, json.dumps(payload).encode(), headers)
component = json.loads(result)['components'][0]
assert json.loads(component['snapshot'])['data']['name'] == 'Debian ISO', 'Search update lost'
assert component['effects'].get('html'), 'Livewire search did not return rendered HTML'
print('HTTP_SESSION_RESULT=PASS: owner login, session, CSRF rejection, Livewire search')
