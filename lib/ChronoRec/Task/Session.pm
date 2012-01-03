package ChronoRec::Task::Session;

use namespace::autoclean;

use Moose;
use MooseX::Storage;

use DateTime::Span;

with Storage format => 'YAML', io => 'File';

has date_start =>
	is			=> 'ro',
	isa			=> 'DateTime',
	required	=> 1,
	default		=> sub { DateTime->now(time_zone => 'local') };

has date_stop =>
	is			=> 'rw',
	isa			=> 'DateTime';

sub duration
{
	my $self	= shift;
	my $window	= shift;

	my $start	= $self->date_start;
	my $stop	= $self->date_stop || DateTime->now(time_zone => 'local');
	my $span	= DateTime::Span->from_datetimes(start => $start, end => $stop);

	return $window->intersection($span)->duration;
}

1;

