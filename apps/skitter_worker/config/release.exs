# Copyright 2018 - 2020, Mathijs Saey, Vrije Universiteit Brussel

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

# Runtime configuration of a skitter worker release. Anything in this file is executed after the
# ERTS is started, but before any skitter applications are loaded.
#
# Skitter releases are configured through environment variables which are set by the skitter
# deployment script (`rel/skitter.sh.eex`)

import Skitter.Application.Config

config_from_env :skitter_worker, :master, "SKITTER_MASTER", &String.to_atom/1

config_enabled_unless_set :skitter_worker,
                          :shutdown_with_master,
                          "SKITTER_NO_SHUTDOWN_WITH_MASTER"