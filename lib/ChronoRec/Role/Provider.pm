package ChronoRec::Role::Provider;

use Moose::Role;

requires 'initialize';
requires 'get_task_names';
requires 'write_sessions';

sub find_matching_tasks
{
	my $self = shift;
	my $text = shift;

	return grep /^$text/i, $self->get_task_names;
}

1;
