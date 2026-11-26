#!/usr/bin/env bash
# Example scripts/post-deploy.sh for a Laravel app. deploy.sh runs it from the repo root after the swap.
set -euo pipefail

php artisan optimize
# `optimize` also caches the config. Clear it again if any legacy code still reads getenv() at runtime: with a cached
# config, getenv() returns empty strings in production.
php artisan config:clear

# PHP-FPM keeps compiled code in OPcache; reload it so the new code is served.
sudo -n systemctl reload php8.2-fpm 2>/dev/null || true
