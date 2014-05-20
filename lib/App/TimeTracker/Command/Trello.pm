package App::TimeTracker::Command::Trello;
use strict;
use warnings;
use 5.010;

# ABSTRACT: App::TimeTracker Trello plugin
use App::TimeTracker::Utils qw(error_message warning_message);

use Moose::Role;
use WWW::Trello::Lite;

# https://trello.com/1/authorize?key=KEY&name=tracker&expiration=1day&response_type=token&scope=read,write

has 'trello' => (
    is            => 'rw',
    isa           => 'Str',
    documentation => 'Trello fake id',
    predicate     => 'has_trello'
);

has 'trello_client' => (
    is         => 'ro',
    isa        => 'Maybe[WWW::Trello::Lite]',
    lazy_build => 1,
    traits     => ['NoGetopt'],
    predicate  => 'has_trello_client'
);

has 'trello_card' => (
    is         => 'ro',
    lazy_build => 1,
    traits     => ['NoGetopt'],
    predicate  => 'has_trello_card'
);

sub _build_trello_card {
    my ($self) = @_;

    return unless $self->has_trello;
    return $self->_trello_fetch_card( $self->trello );
}

sub _build_trello_client {
    my $self   = shift;
    my $config = $self->config->{trello};

    unless ($config) {
        error_message("Please configure Trello in your TimeTracker config");
        return;
    }
    return WWW::Trello::Lite->new(
        key   => $self->config->{trello}{key},
        token => $self->config->{trello}{token},
    );
}

after '_load_attribs_stop' => sub {
    my ( $class, $meta ) = @_;

    $meta->add_attribute(
        'move_to' => {
            isa           => 'Str',
            is            => 'ro',
            documentation => 'Move Card to ...',
        }
    );
};

before [ 'cmd_start', 'cmd_continue', 'cmd_append' ] => sub {
    my $self = shift;
    return unless $self->has_trello;

    my $cardname = 'trello:' . $self->trello;
    $self->insert_tag($cardname);

    my $name;
    my $card = $self->trello_card;
    return unless $card;

    if ( $self->trello_client ) {
        my $card = $self->trello_card;
        if ( defined $card ) {
            $name = $self->_trello_just_the_name($card);
            if ( defined $self->description ) {
                $self->description( $self->description . ' ' . $name );
            }
            else {
                $self->description($name);
            }
        }
    }

    if ( $self->meta->does_role('App::TimeTracker::Command::Git') ) {
        my $branch = $self->trello;
        if ($name) {
            $branch .= '_' . $self->safe_branch_name($name);
        }
        $self->branch($branch) unless $self->branch;
    }
};

after [ 'cmd_start', 'cmd_continue', 'cmd_append' ] => sub {
    my $self = shift;
    return unless $self->has_trello_card;

    my $card = $self->trello_card;

    if ( my $lists = $self->_trello_fetch_lists ) {
        if ( $lists->{doing} ) {
            unless ( $card->{idList} eq $lists->{doing}->{id} ) {
                $self->trello_client->put(
                    'cards/' . $card->{id} . '/idList',
                    { value => $lists->{doing}->{id} }
                );
            }
        }
    }

    if ( my $member_id = $self->config->{trello}{member_id} ) {
        unless ( grep { $_ eq $member_id } @{ $card->{idMembers} } ) {
            my $members = $card->{idMembers};
            push( @$members, $member_id );
            $self->trello_client->put(
                'cards/' . $card->{id} . '/idMembers',
                { value => join( ',', @$members ) }
            );
        }
    }
};

after 'cmd_stop' => sub {
    my $self = shift;
    return unless $self->has_trello;

    my $task = $self->_previous_task;
    return unless $task;
    my $task_rounded_minutes = $task->rounded_minutes;

    my $card = $self->_trello_fetch_card( $task->trello_card_id );

    unless ($card) {
        warning_message(
            "Last task did not contain a trello id, not updating time etc.");
        return;
    }

    my $name = $card->{name};
    my %update;

    if (    $self->config->{trello}{update_time_worked}
        and $task_rounded_minutes ) {
        if ( $name =~ /\[w:(\d+)m\]/ ) {
            my $new_worked = $1 + $task_rounded_minutes;
            $name =~ s/\[w:\d+m\]/'[w:'.$new_worked.'m]'/e;
        }
        else {
            $name .= ' [w:' . $task_rounded_minutes . 'm]';
        }
        $update{name} = $name;
    }

    if ( my $move_to = $self->move_to ) {
        if ( my $lists = $self->_trello_fetch_lists ) {
            if ( $lists->{$move_to} ) {
                $update{idList} = $lists->{$move_to}->{id};
            }
            else {
                warning_message("Could not find list >$move_to<");
            }
        }
        else {
            warning_message("Could not load lists");
        }
    }

    return unless keys %update;

    $self->trello_client->put( 'cards/' . $card->{id}, \%update );
};

sub _trello_fetch_card {
    my ( $self, $trello_tag ) = @_;

    my %search = ( query => $trello_tag, card_fields => 'name' );

    if ( my $board_id = $self->config->{trello}{board_id} ) {
        $search{idBoards} = $board_id;
    }

    my $result = $self->trello_client->get( "search", \%search )->data;
    my $cards = $result->{cards};
    unless ( @$cards == 1 ) {
        warning_message(
            "Could not identify trello card via '" . $trello_tag . "'" );
        return;
    }
    my $id   = $cards->[0]{id};
    my $card = $self->trello_client->get( 'cards/' . $id )->data;
    return $card;
}

sub _trello_fetch_lists {
    my $self     = shift;
    my $board_id = $self->config->{trello}{board_id};
    return unless $board_id;
    my $rv =
        $self->trello_client->get( 'boards/' . $board_id . '/lists' )->data;

    my %lists;
    my $map = $self->config->{trello}{list_map}
        || {
        'To Do' => 'todo',
        'Doing' => 'doing',
        'Done'  => 'done',
        };
    foreach my $list (@$rv) {
        next unless my $tracker_name = $map->{ $list->{name} };
        $lists{$tracker_name} = $list;
    }
    return \%lists;
}

sub _trello_just_the_name {
    my ( $self, $card ) = @_;
    my $name = $card->{name};
    my $tr   = $self->trello;
    $name =~ s/$tr:\s?//;
    $name =~ s/\[(.*?\])//;
    $name =~ s/\s+//;
    return $name;
}

sub App::TimeTracker::Data::Task::trello_card_id {
    my $self = shift;
    foreach my $tag ( @{ $self->tags } ) {
        next unless $tag =~ /^trello:(\w+)/;
        return $1;
    }
}

no Moose::Role;
1;

__END__

=head1 DESCRIPTION

This plugin takes a lot of hassle out of working with Trello
L<http://trello.com/>.

It can set the description and tags of the current task based on data
entered into RT, set the owner of the ticket and update the
time-worked as well as time-left in RT. If you also use the C<Git> plugin, this plugin will
generate very nice branch names based on RT information.

=head1 CONFIGURATION

=head2 plugins

Add C<RT> to the list of plugins. 

=head2 rt

add a hash named C<rt>, containing the following keys:

=head3 server [REQUIRED]

The server name RT is running on.

=head3 username [REQUIRED]

Username to connect with. As the password of this user might be distributed on a lot of computer, grant as little rights as needed.

=head3 password [REQUIRED]

Password to connect with.

=head3 timeout

Time in seconds to wait for an connection to be established. Default: 300 seconds (via RT::Client::REST)

=head3 set_owner_to

If set, set the owner of the current ticket to the specified value during C<start> and/or C<stop>.

=head3 update_time_worked

If set, updates the time worked on this task also in RT.

=head3 update_time_left

If set, updates the time left property on this task also in RT using the time worked tracker value.

=head1 NEW COMMANDS

none

=head1 CHANGES TO OTHER COMMANDS

=head2 start, continue

=head3 --rt

    ~/perl/Your-Project$ tracker start --rt 1234

If C<--rt> is set to a valid ticket number:

=over

=item * set or append the ticket subject in the task description ("Rev up FluxCompensator!!")

=item * add the ticket number to the tasks tags ("RT1234")

=item * if C<Git> is also used, determine a save branch name from the ticket number and subject, and change into this branch ("RT1234_rev_up_fluxcompensator")

=item * set the owner of the ticket in RT (if C<set_owner_to> is set in config)

=item * updates the status of the ticket in RT (if C<set_status/start> is set in config)

=back

=head2 stop

If <update_time_worked> is set in config, adds the time worked on this task to the ticket.
If <update_time_left> is set in config, reduces the time left on this task to the ticket.
If <set_status/stop> is set in config, updates the status of the ticket

