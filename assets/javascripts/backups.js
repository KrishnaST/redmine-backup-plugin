document.addEventListener('DOMContentLoaded', function () {
    const secondary = document.getElementById('backup_secondary_enabled');
    const fields = document.getElementById('backup-secondary-fields');
    const updateSecondary = function () { fields.hidden = !secondary.checked; };
    secondary.addEventListener('change', updateSecondary);
    updateSecondary();
    document.querySelectorAll('.backup-provider').forEach(function (selector) {
        const update = function () {
            document.querySelectorAll('.backup-provider-fields').forEach(function (group) {
                if (group.dataset.slot !== selector.dataset.slot) return;
                group.hidden = group.dataset.provider === 'cloud' ? !['google_drive', 'onedrive'].includes(selector.value) : group.dataset.provider !== selector.value;
            });
        };
        selector.addEventListener('change', update);
        update();
    });
});
