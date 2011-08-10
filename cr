#!/usr/bin/env perl

use MooseX::Declare;

MooseX::Storage::Engine->add_custom_type_handler(
	DateTime =>
		expand		=> sub { DateTime::Format::ISO8601->parse_datetime(shift) },
		collapse	=> sub { shift->iso8601 }
);

{
    package DateTime::Duration;

	sub stringify
	{
		use DateTime::Format::Duration;

		my $d = new DateTime::Format::Duration pattern => '%H:%M:%S', normalize => 1;

		return $d->format_duration(shift);
	}

	use overload '""' => \&stringify;
}


class chronorec with MooseX::Getopt {
	use MooseX::POE::SweetArgs;
	use POE::Wheel::ReadLine;
	use Path::Class::Dir;
	use Try::Tiny;
	use DateTime;
	use Data::Dump;
	use Data::Dump::Filtered;
	use CHI;

	Data::Dump::Filtered::add_dump_filter(sub { shift->class eq 'DateTime' ? { object => shift->iso8601 } : undef });

	use chronorec::task;
	use chronorec::task::session;

	has database => (is => 'rw', isa => 'Str', default => 'local');

	has home =>
		is			=> 'ro',
		isa			=> 'Path::Class::Dir',
		lazy_build	=> 1;

	has console =>
		is			=> 'ro',
		isa			=> 'POE::Wheel::ReadLine',
		lazy_build	=> 1;

	has store =>
		is			=> 'ro',
		isa			=> 'CHI::Driver',
		lazy_build	=> 1;

	has current =>
		is			=> 'rw',
		isa			=> 'chronorec::task';

	method _build_home
	{
		my $path = Path::Class::Dir->new((getpwuid($<))[7] . '/.' . ref $self);

		do { $path->mkpath or die "unable to make path $path: $!" }
			if not -e $path;

		return $path;
	}

	method _build_console
	{
		my $wheel = new POE::Wheel::ReadLine InputEvent => 'input';

		$wheel->read_history($self->home->file('history'));
		$wheel->get(ref($self) . '> ');

		return $wheel;
	}

	method _build_store
	{
		new CHI
			driver		=> 'File',
			namespace	=> ref($self),
			root_dir	=> $self->home->subdir('store')->stringify,
			l1_cache	=> { driver => 'Memory', datastore => {} };
	}

	method START
	{
		my $hash = $self->store->get('current');
		my $task = $self->store->get($hash);

		$self->current($task);
		$self->alarm_add(tick => time + 1);
	}

	method STOP
	{
		$self->console->write_history($self->home->file('history'));
	}

	event dump => sub
	{
		my $self = shift;
		my $key	= shift;

		dd $self->store->get($key);
	};

	event tick => sub
	{
		my $self = shift;

		my $prompt = ref $self;

		if ($self->current and $self->current->is_active) {
			$prompt .= ' T=' . $self->current->duration;
			$prompt .= ' S=' . $self->current->get_session(-1)->duration;
		}

		$self->console->get($prompt . '> ');
		$self->alarm_add(tick => time + 1);
	};

	event input => sub
	{
		my $self	= shift;
		my $text	= shift;
		my $ex		= shift;

		$self->alarm_remove_all if $ex eq 'eot';

		my ($op, $args) = split /\s+/, $text, 2;

		return if not defined $op;

		$self->call($op, $args) or $self->console->put("unknown command $op");

		$self->console->addhistory($text);
	};

	event list => sub
	{
		my $self = shift;

		dd $self->store->get_keys;
	};

	event info => sub
	{
		my $self = shift;
		my $hash = shift;

		my $task = $self->store->get($hash);

		$self->console->put('description: ' . $task->description);
		$self->console->put('time: ' . $task->duration);
	};

	event start => sub {
		my $self = shift;
		my $text = shift;

		if ($self->current and $self->current->is_active) {
			$self->console->put('another task in progress');
			return 1;
		}

		if ($self->current and not defined $text) {
			$self->current->start;
			$self->store->set($self->current->hash => $self->current);

			return 1;
		}

		my $task	= new chronorec::task description => $text;
		my $id		= $task->hash;
		my $expires	= $task->date_created->clone->add(hours => 48)->epoch;

		$task->add_session(new chronorec::task::session);

		$self->store->set($id => $task => { expires_at => $expires });
		$self->store->set(current => $id);

		$self->current($task);
	};

	event stop => sub
	{
		my $self = shift;
		my $text = shift;

		my $task = $self->current;

		if (not $task or not $task->is_active) {
			$self->console->put('no task in progress');
			return;
		}

		$task->stop;
		$self->store->set($task->hash => $task);
	};
}

chronorec->new_with_options;
POE::Kernel->run;

