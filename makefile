all: compile

compile: 
	erl -make

clean:
	rm ebin/*.beam

run:
	erl -eval 'application:start(eirc)' -sname console -pa ebin

shell:
	erl -sname console -pa ebin

check:
	dialyzer -r ebin/ --src src/
