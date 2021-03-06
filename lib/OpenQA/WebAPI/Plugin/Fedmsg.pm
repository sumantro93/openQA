# Copyright (C) 2016 Red Hat
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::WebAPI::Plugin::Fedmsg;

use strict;
use warnings;

use parent qw/Mojolicious::Plugin/;
use IPC::Run;
use JSON;
use Mojo::IOLoop;
use OpenQA::Schema::Result::Jobs;

my @events = qw/job_create job_delete job_cancel job_duplicate job_restart jobs_restart job_update_result job_done/;

sub register {
    my ($self, $app) = @_;
    my $reactor = Mojo::IOLoop->singleton;

    # register for events
    for my $e (@events) {
        $reactor->on("openqa_$e" => sub { shift; $self->on_event($app, @_) });
    }
}

# when we get an event, convert it to fedmsg format and send it
sub on_event {
    my ($self, $app, $args) = @_;
    my ($user_id, $connection_id, $event, $event_data) = @$args;
    # we're going to explicitly pass this as the modname
    $event =~ s/^openqa_//;
    # fedmsg uses dot separators
    $event =~ s/_/\./;
    # find count of pending jobs for the same build
    # this is so we can tell when all tests for a build are done
    my $job = $app->db->resultset('Jobs')->find({id => $event_data->{id}});
    my $build = $job->settings_hash->{BUILD};
    $event_data->{remaining} = $app->db->resultset('Jobs')->search(
        {
            'settings.key'   => 'BUILD',
            'settings.value' => $build,
            state            => [OpenQA::Schema::Result::Jobs::PENDING_STATES],
        },
        {join => qw/settings/})->count;
    # add various useful properties for consumers if not there already
    $event_data->{BUILD}   //= $build;
    $event_data->{TEST}    //= $job->test;
    $event_data->{ARCH}    //= $job->settings_hash->{ARCH};
    $event_data->{MACHINE} //= $job->settings_hash->{MACHINE};
    $event_data->{FLAVOR}  //= $job->settings_hash->{FLAVOR};
    $event_data->{ISO}     //= $job->settings_hash->{ISO} if ($job->settings_hash->{ISO});
    $event_data->{HDD_1}   //= $job->settings_hash->{HDD_1} if ($job->settings_hash->{HDD_1});
    # convert data to JSON, with reliable key ordering (helps the tests)
    $event_data = to_json($event_data, {canonical => 1});
    $app->log->debug("Sending fedmsg for $event");
    # do you want to write perl bindings for fedmsg? no? me either.
    # FIXME: should be some way for plugins to have configuration and then
    # cert-prefix could be configurable, for now we hard code it
    # we use IPC::Run rather than system() as it's easier to mock for testing
    my @command = ("fedmsg-logger", "--cert-prefix=openqa", "--modname=openqa", "--topic=$event", "--json-input", "--message=$event_data");
    my ($stdin, $stderr, $output) = (undef, undef, undef);
    IPC::Run::run(\@command, \$stdin, \$output, \$stderr);
}

1;
