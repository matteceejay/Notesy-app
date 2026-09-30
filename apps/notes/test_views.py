"""Extra view tests: auth flow, detail, editor GETs, summarize, and __str__."""
import secrets
from unittest import mock

import pytest
from django.contrib.auth import get_user_model
from django.test import Client

from apps.notes.models import Note


@pytest.fixture
def password():
    return secrets.token_urlsafe(16)


@pytest.fixture
def carol(db, password):
    return get_user_model().objects.create_user(username="carol", password=password)


@pytest.fixture
def carol_client(carol):
    c = Client()
    c.force_login(carol)
    return c


def test_login_page_renders(db):
    response = Client().get("/login/")
    assert response.status_code == 200


def test_login_success_redirects_to_list(carol, password):
    response = Client().post("/login/", {"username": "carol", "password": password})
    assert response.status_code == 302
    assert response.url == "/"


def test_login_failure_shows_error(carol):
    response = Client().post("/login/", {"username": "carol", "password": "wrong"})
    assert response.status_code == 200
    assert b"Invalid credentials" in response.content


def test_logout_redirects_to_login(carol_client):
    response = carol_client.get("/logout/")
    assert response.status_code == 302
    assert response.url == "/login/"


def test_list_requires_login(db):
    response = Client().get("/")
    assert response.status_code == 302
    assert "/login/" in response.url


def test_note_detail(carol_client, carol):
    note = Note.objects.create(owner=carol, title="Detail me", body="x")
    response = carol_client.get(f"/notes/{note.pk}/")
    assert response.status_code == 200
    assert b"Detail me" in response.content


def test_note_detail_of_other_user_is_404(carol_client, db):
    other = get_user_model().objects.create_user(username="dave")
    note = Note.objects.create(owner=other, title="Not yours")
    assert carol_client.get(f"/notes/{note.pk}/").status_code == 404


def test_new_note_editor_renders(carol_client):
    assert carol_client.get("/notes/new/").status_code == 200


def test_edit_note_editor_renders(carol_client, carol):
    note = Note.objects.create(owner=carol, title="Edit me")
    assert carol_client.get(f"/notes/{note.pk}/edit/").status_code == 200


@mock.patch("apps.notes.views.time.sleep")
def test_summarize_short_note(mock_sleep, carol_client, carol):
    note = Note.objects.create(owner=carol, title="Short", body="tiny body")
    response = carol_client.post(f"/notes/{note.pk}/summarize/")
    assert response.status_code == 200
    note.refresh_from_db()
    assert note.summary == "tiny body"
    mock_sleep.assert_called_once()


@mock.patch("apps.notes.views.time.sleep")
def test_summarize_long_note_is_truncated(mock_sleep, carol_client, carol):
    note = Note.objects.create(owner=carol, title="Long", body="a" * 200)
    carol_client.post(f"/notes/{note.pk}/summarize/")
    note.refresh_from_db()
    assert note.summary == "a" * 140 + "..."


def test_note_str(carol):
    assert str(Note(owner=carol, title="Hello")) == "Hello"
    assert str(Note(owner=carol, title="", pk=7)) == "Note #7"