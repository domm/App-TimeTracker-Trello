package App::TimeTracker::Command::Trello;
use strict;
use warnings;
use 5.010;

# ABSTRACT: App::TimeTracker Trello plugin
use App::TimeTracker::Utils qw(error_message warning_message);

our $VERSION = "1.000";

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
        $self->branch(lc($branch)) unless $self->branch;
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

Using the Trello plugin, tracker can fetch the name of a Card and use
it as the task's description; generate a nicely named C<git> branch
(if you're also using the C<Git> plugin); add the user as a member to
the Card; move the card to various lists; and use some hackish
extension to the Card name to store the time-worked in the Card.

=head1 CONFIGURATION

=head2 plugins

Add C<Trello> to the list of plugins. 

=head2 trello

add a hash named C<trello>, containing the following keys:

=head3 key [REQUIRED]

Your Trello Developer Key. Get it from L<https://trello.com/1/appKey/generate>

=head3 token [REQUIRED]

Your access token. Get it from
L<https://trello.com/1/authorize?key=YOUR_DEV_KEY&name=tracker&expiration=1day&response_type=token&scope=read,write>.
You maybe want to set a longer expiration timeframe.

I will probably add some commands to this plugin to make getting the token easier.

=head3 board_id [SORT OF REQUIRED]

The C<board_id> of the board you want to use.

Not stictly necessary, as we use fake ids to identify cards. But if you don't specify the C<board_id> the search for those ids will be global over all your boards, so you would have to make sure to not use the same id more than once in all those boards.

If you specify the C<board_id>, C<tracker> will only search in this board.

You can get the C<board_id> by going to "Share, print and export" in the sidebar menu, click "Export JSON" and then find the C<id> in the toplevel hash.

=head3 member_id

Your trello C<member_id>.

Needed for adding you to a Card's list of members. Currently a bit hard to get from trello...

=head3 update_time_worked

If set, updates the time worked on this task on the Trello Card.

As Trello does not provide time-tracking (yet?), we store the time-worked in some simple markup in the Card name:

  Callibrate FluxCompensator [w:32m]

C<[w:32m]> means that you worked 32 minutes on the task.

=head1 NEW COMMANDS

none yet

=head1 CHANGES TO OTHER COMMANDS

=head2 start, continue

=head3 --trello

    ~/perl/Your-Project$ tracker start --trello t123

If C<--trello> is set and we can find a matching card:

=over

=item * set or append the Card name in the task description ("Rev up FluxCompensator!!")

=item * add the Card FakeID to the tasks tags ("trello:t123")

=item * if C<Git> is also used, determine a save branch name from the Card name, and change into this branch ("t123_rev_up_fluxcompensator")

=item * add member to list of members (if C<member_id> is set in config)

=item * move to C<Doing> list (if there is such a list, or another list is defined in C<list_map> in config)

=back

=head2 stop

=over

=item * If <update_time_worked> is set in config, adds the time worked on this task to the Card.

=item * If --move_to is specified and a matching list is found in C<list_map> in config, move the Card to this list.

=back

