const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

class Field {
    constructor(value = '') {
        this.value = value;
        this.disabled = false;
        this.listeners = {};
    }

    addEventListener(name, callback) {
        this.listeners[name] = callback;
    }
}

const provider = new Field('google_drive');
const authentication = new Field('oauth2');
authentication.options = [
    ['oauth2', 'google_drive onedrive'], ['ssh_key', 'sftp'], ['password', 'sftp'],
    ['sdk_chain', 's3'], ['access_key', 's3'], ['session_token', 's3']
].map(([value, providers]) => Object.assign(new Field(value), { dataset: { providers } }));
Object.defineProperty(authentication, 'selectedOptions', {
    get: function () { return this.options.filter((option) => option.value === this.value); }
});
const secondary = Object.assign(new Field(), { checked: true });
const groups = [['google_drive onedrive', ''], ['onedrive', ''], ['s3', ''],
    ['s3', 'access_key session_token'], ['s3', 'session_token'], ['sftp', 'ssh_key'], ['sftp', 'password']]
    .map(([providers, methods]) => ({
        dataset: { providers, methods }, fields: [new Field()],
        querySelectorAll: function () { return this.fields; }
    }));
const body = { querySelectorAll: () => [provider, authentication, ...groups.flatMap((group) => group.fields)] };
const destination = {
    querySelector: (selector) => ({ '.backup-secondary-enabled': secondary, '.backup-destination-body': body,
        '.backup-provider': provider, '.backup-authentication': authentication })[selector],
    querySelectorAll: () => groups
};
const document = {
    querySelectorAll: () => [destination],
    addEventListener: (_event, callback) => callback()
};
vm.runInNewContext(fs.readFileSync('assets/javascripts/backups.js', 'utf8'), { document });
assert.equal(groups[0].hidden, false);
assert.equal(groups[1].fields[0].disabled, true);
provider.value = 's3';
provider.listeners.change();
assert.equal(authentication.value, 'sdk_chain');
assert.equal(groups[0].fields[0].disabled, true);
assert.equal(groups[2].hidden, false);
assert.equal(groups[3].hidden, true);
authentication.value = 'session_token';
authentication.listeners.change();
assert.equal(groups[3].hidden, false);
assert.equal(groups[4].hidden, false);
provider.value = 'sftp';
provider.listeners.change();
assert.equal(authentication.value, 'ssh_key');
assert.equal(groups[5].hidden, false);
assert.equal(groups[6].hidden, true);
authentication.value = 'password';
authentication.listeners.change();
assert.equal(groups[5].fields[0].disabled, true);
assert.equal(groups[6].hidden, false);
secondary.checked = false;
secondary.listeners.change();
assert.equal(body.hidden, true);
assert.ok(body.querySelectorAll().every((field) => field.disabled));
console.log('Provider form: OAuth, S3 chain/STS, SFTP key/password and optional-secondary transitions passed.');
