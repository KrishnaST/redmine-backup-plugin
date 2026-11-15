"""Read the deployed backup page through Redmine's normal HTTPS login. No email or backup actions."""

import argparse
import getpass
import http.cookiejar
import json
import urllib.parse
import urllib.request
from html.parser import HTMLParser


class LoginForm(HTMLParser):
    def __init__(self):
        super().__init__()
        self.fields = {}

    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        if tag == "input" and attributes.get("type") == "hidden" and attributes.get("name"):
            self.fields[attributes["name"]] = attributes.get("value", "")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--username", required=True)
    arguments = parser.parse_args()
    if urllib.parse.urlparse(arguments.url).scheme != "https":
        parser.error("HTTPS is required")
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    opener.addheaders = [("User-Agent", "Mozilla/5.0 (Redmine deployment verification)")]
    login_url = arguments.url.rstrip("/") + "/login"
    form = LoginForm()
    form.feed(opener.open(login_url, timeout=30).read().decode("utf-8"))
    password = getpass.getpass("Redmine password (not stored): ")
    form.fields.update({"username": arguments.username, "password": password})
    authenticated = opener.open(login_url, urllib.parse.urlencode(form.fields).encode(), timeout=30)
    if urllib.parse.urlparse(authenticated.url).path.endswith("/login"):
        print(json.dumps({"authenticated": False}))
        return 1
    response = opener.open(arguments.url.rstrip("/") + "/admin/backups", timeout=30)
    page = response.read().decode("utf-8")
    valid = response.status == 200 and "Local successful dates to keep" in page and "Secondary destination" in page
    provider_form = 'backup-authentication' in page and 'Save settings and connect storage account' in page
    homepage = opener.open(arguments.url.rstrip("/") + "/", timeout=30).read().decode("utf-8")
    summary = 'redmine-backup-home-status' in homepage and 'Last successful local capture' in homepage
    valid = valid and provider_form and summary
    print(json.dumps({"authenticated": True, "backup_page_status": response.status, "expected_controls_present": valid,
                      "provider_specific_form": provider_form, "administrator_homepage_summary": summary}))
    return 0 if valid else 1


if __name__ == "__main__":
    raise SystemExit(main())
