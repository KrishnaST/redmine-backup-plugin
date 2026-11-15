document.addEventListener('DOMContentLoaded', function () {
    document.querySelectorAll('.backup-destination').forEach(function (destination) {
        const enabled = destination.querySelector('.backup-secondary-enabled');
        const body = destination.querySelector('.backup-destination-body');
        const provider = destination.querySelector('.backup-provider');
        const authentication = destination.querySelector('.backup-authentication');
        const update = function () {
            const active = !enabled || enabled.checked;
            body.hidden = !active;
            body.querySelectorAll('input, select, button, textarea').forEach(function (field) {
                field.disabled = !active;
            });
            Array.from(authentication.options).forEach(function (option) {
                const supported = option.dataset.providers.split(' ').includes(provider.value);
                option.hidden = !supported;
                option.disabled = !supported;
            });
            if (authentication.selectedOptions.length === 0 || authentication.selectedOptions[0].disabled) {
                const first = Array.from(authentication.options).find(function (option) { return !option.disabled; });
                authentication.value = first ? first.value : '';
            }
            destination.querySelectorAll('.backup-provider-fields').forEach(function (group) {
                const providerMatches = group.dataset.providers.split(' ').includes(provider.value);
                const methodMatches = !group.dataset.methods || group.dataset.methods.split(' ').includes(authentication.value);
                const visible = active && providerMatches && methodMatches;
                group.hidden = !visible;
                group.querySelectorAll('input, select, button, textarea').forEach(function (field) {
                    field.disabled = !visible;
                });
            });
        };
        provider.addEventListener('change', update);
        authentication.addEventListener('change', update);
        if (enabled) enabled.addEventListener('change', update);
        update();
    });
});
