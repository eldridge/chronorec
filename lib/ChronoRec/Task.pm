package ChronoRec::Task;

use namespace::autoclean;

use Moose;
use MooseX::Storage;

with Storage format => 'YAML', io => 'File';

use Digest::SHA1;

has description =>
	is			=> 'ro',
	isa			=> 'Str',
	required	=> 1;

has date_created =>
	is			=> 'ro',
	isa			=> 'DateTime',
	required	=> 1,
	default		=> sub { DateTime->now(time_zone => 'local') };

has sessions =>
	is			=> 'ro',
	isa			=> 'ArrayRef[ChronoRec::Task::Session]',
	default		=> sub { [] },
	traits		=> [ 'Array' ],
	handles		=> {
		add_session			=> 'push',
		get_session			=> 'get',
		get_all_sessions	=> 'elements'
	};

sub hash
{
	my $self = shift;

	my $sha = new Digest::SHA1;

	$sha->add(join 0x1e, $self->date_created, $self->description);

	return $sha->hexdigest;
}

sub is_active
{
	my $self = shift;

	return not defined $self->get_session(-1)->date_stop;
}

sub duration
{
	my $self	= shift;
	my $window	= shift;

	my $total = new DateTime::Duration;

	$total += $_->duration($window) foreach $self->get_all_sessions;

	return $total->clock_duration;
}

sub start
{
	my $self = shift;

	return if $self->is_active;

	$self->add_session(new ChronoRec::Task::Session);
}

sub stop
{
	my $self = shift;

	return unless $self->is_active;

	my $session = $self->get_session(-1);

	$session->date_stop(DateTime->now(time_zone => 'local'));
}

1;

