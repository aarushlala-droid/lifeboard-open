import { next } from '@vercel/functions';
import { authorise } from './lib/auth.js';
import { databaseStore } from './lib/store.js';
export default async function middleware(request){try{const headers=Object.fromEntries(request.headers);if(await authorise({headers},databaseStore()))return next();}catch{}return Response.redirect(new URL('/connect.html',request.url),302);}
export const config={matcher:'/',runtime:'nodejs'};
