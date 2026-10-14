// Google OAuth client ID (Web application type) from Google Cloud Console.
// Add your local origin (e.g. http://localhost:8000) under "Authorized JavaScript origins".
// Leave empty to run on demo data only.
export const GOOGLE_CLIENT_ID = '';

export const CALENDAR_SCOPE = 'https://www.googleapis.com/auth/calendar.readonly';
// Only requested when you add an event from an unscheduled block.
export const CALENDAR_WRITE_SCOPE = 'https://www.googleapis.com/auth/calendar.events';
