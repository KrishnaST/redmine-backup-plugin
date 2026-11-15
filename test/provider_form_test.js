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
    ['oauth2', 'google_drive onedrive onedrive_personal sharepoint'],
    ['device_code', 'onedrive onedrive_personal sharepoint'],
    ['service_account', 'google_drive'], ['domain_delegation', 'google_drive'],
    ['client_secret', 'onedrive sharepoint'], ['certificate', 'onedrive sharepoint'],
    ['workload_identity', 'onedrive sharepoint'], ['managed_identity', 'onedrive sharepoint'],
    ['on_behalf_of', 'onedrive sharepoint'], ['password_grant', 'onedrive sharepoint'],
    ['imported_token', 'google_drive onedrive onedrive_personal sharepoint'],
    ['ssh_key', 'sftp'], ['password', 'sftp'],
    ['sdk_chain', 's3'], ['access_key', 's3'], ['session_token', 's3']
].map(([value, providers]) => Object.assign(new Field(value), { dataset: { providers } }));
Object.defineProperty(authentication, 'selectedOptions', {
    get: function () { return this.options.filter((option) => option.value === this.value); }
});
const secondary = Object.assign(new Field(), { checked: true });
const groups = [['google_drive onedrive onedrive_personal sharepoint', ''], ['onedrive sharepoint', ''], ['s3', ''],
    ['s3', 'access_key session_token'], ['s3', 'session_token'], ['sftp', 'ssh_key'], ['sftp', 'password'],
    ['google_drive', 'service_account domain_delegation'], ['onedrive sharepoint', 'certificate'],
    ['onedrive sharepoint', 'on_behalf_of'], ['onedrive sharepoint', 'password_grant'],
    ['google_drive onedrive onedrive_personal sharepoint', 'imported_token']]
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
provider.value = 'onedrive_personal';
provider.listeners.change();
assert.equal(authentication.value, 'oauth2');
assert.ok(authentication.options.find((option) => option.value === 'client_secret').disabled);
assert.ok(!authentication.options.find((option) => option.value === 'device_code').disabled);
provider.value = 'sharepoint';
provider.listeners.change();
authentication.value = 'certificate';
authentication.listeners.change();
assert.equal(groups[8].fields[0].disabled, false);
assert.equal(groups[7].fields[0].disabled, true);
assert.equal(groups[10].fields[0].disabled, true);
authentication.value = 'password_grant';
authentication.listeners.change();
assert.equal(groups[8].fields[0].disabled, true);
assert.equal(groups[10].fields[0].disabled, false);
provider.value = 'google_drive';
provider.listeners.change();
assert.equal(authentication.value, 'oauth2');
authentication.value = 'service_account';
authentication.listeners.change();
assert.equal(groups[7].fields[0].disabled, false);
assert.equal(groups[8].fields[0].disabled, true);
authentication.value = 'imported_token';
authentication.listeners.change();
assert.equal(groups[7].fields[0].disabled, true);
assert.equal(groups[11].fields[0].disabled, false);
secondary.checked = false;
secondary.listeners.change();
assert.equal(body.hidden, true);
assert.ok(body.querySelectorAll().every((field) => field.disabled));
console.log('Provider form: personal/business account methods, service/certificate/legacy/token fields, S3/SFTP and optional-secondary transitions passed.');
